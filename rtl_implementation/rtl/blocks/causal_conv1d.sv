module causal_conv1d #(
  parameter IN_CHANNELS  = 1,
  parameter OUT_CHANNELS = 1,

  parameter KERNEL_SIZE  = 3,
  parameter DILATION     = 1,

  parameter DATA_WIDTH   = 16,
  parameter ACC_WIDTH    = 32,

  parameter WEIGHT_FILE  = "weights.hex",
  parameter BIAS_FILE    = "bias.hex",

  parameter APPLY_RELU   = 1,

  // Fractional bits in Q format: right-shift accumulator by this many bits
  // after MAC before adding bias.  0 = integer-only (backward compat).
  // Set to 8 when using Q8.8 weights exported from the Python model.
  parameter FRAC_BITS    = 0
)(
  input  wire                                   clk,
  input  wire                                   rst_n,

  input  wire                                   en,
  // flat packed vector: channel ch occupies bits [ch * DW +: DW]
  input  wire [IN_CHANNELS*DATA_WIDTH  - 1 : 0] data_in,

  output reg  [OUT_CHANNELS*DATA_WIDTH - 1 : 0] data_out,
  output reg                                    valid_out
);

  localparam DEPTH         = (KERNEL_SIZE - 1) * DILATION;
  localparam STEPS_PER_OUT = IN_CHANNELS * KERNEL_SIZE;
  localparam MEM_DEPTH     = OUT_CHANNELS * STEPS_PER_OUT;
  localparam ADDR_W        = $clog2(MEM_DEPTH) + 1;

  localparam CNT_SETTLE    = STEPS_PER_OUT + 1;
  localparam CNT_SAVE      = STEPS_PER_OUT + 2;
  localparam CNT_W         = $clog2(CNT_SAVE + 1) + 1;

  localparam OUT_CNT_W     = $clog2(OUT_CHANNELS) + 1;
  localparam IN_CNT_W      = $clog2(IN_CHANNELS)  + 1;

  localparam K_CNT_W       = $clog2(KERNEL_SIZE)  + 1;

  reg signed  [DATA_WIDTH - 1 : 0] weight_mem   [0 : MEM_DEPTH - 1];
  reg signed  [DATA_WIDTH - 1 : 0] weight_rd;
  reg         [ADDR_W - 1 : 0]     weight_addr;

  reg signed  [DATA_WIDTH - 1 : 0] bias_mem     [0 : OUT_CHANNELS - 1];

  reg                              mac_en;
  reg                              mac_clear;
  reg  signed [DATA_WIDTH - 1 : 0] mac_data;

  reg         [CNT_W - 1 : 0]      cnt;
  reg signed  [DATA_WIDTH - 1 : 0] tap_latch    [0 : IN_CHANNELS - 1][0 : KERNEL_SIZE - 1];

  reg         [OUT_CNT_W - 1 : 0]  out_cnt;
  reg         [IN_CNT_W - 1 : 0]   in_cnt;
  reg         [K_CNT_W - 1 : 0]    k_cnt;

  wire signed [ACC_WIDTH - 1 : 0]  acc_out;
  wire signed [ACC_WIDTH - 1 : 0]  acc_biased;
  wire signed [DATA_WIDTH - 1 : 0] relu_out;

  // flat: channel ch, delay-tap k → bits [(ch*(DEPTH+1)+k)*DW +: DW]
  wire [(IN_CHANNELS * (DEPTH + 1) * DATA_WIDTH) - 1 : 0] all_taps;

  integer                          i;
  integer                          j;
  integer                          k;

  genvar                           ch;

  initial begin 
    $readmemh   (WEIGHT_FILE, weight_mem);
  end

  initial begin
    $readmemh   (BIAS_FILE, bias_mem);
  end

  // For Q8.8 weights: accumulator holds Q16.16 products; right-shift by
  // FRAC_BITS brings it back to Q8.8 scale before the Q8.8 bias is added.
  wire signed [ACC_WIDTH - 1 : 0] acc_scaled = $signed(acc_out) >>> FRAC_BITS;
  assign acc_biased = acc_scaled + {{(ACC_WIDTH - DATA_WIDTH){bias_mem[out_cnt][DATA_WIDTH - 1]}}, bias_mem[out_cnt]};

  generate
    for (ch = 0; ch < IN_CHANNELS; ch = ch + 1) begin : gen_shift
      shift_reg #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (DEPTH)
      ) shift_reg_01 (
        .clk        (clk),
        .rst_n      (rst_n),

        .en         (en),
        .data_in    ($signed(data_in [ch * DATA_WIDTH +: DATA_WIDTH])),

        // each shift_reg gets its own (DEPTH+1)*DW slice of all_taps
        .taps       (all_taps [ch * (DEPTH + 1) * DATA_WIDTH +: (DEPTH + 1) * DATA_WIDTH])
      );

    end

  endgenerate

  generate
    if (APPLY_RELU) begin : gen_relu
      relu #(
        .DATA_WIDTH (DATA_WIDTH)
      ) relu_01 (
        .data_in    (acc_biased [DATA_WIDTH - 1 : 0]),

        .data_out   (relu_out)
      );
    end else begin : gen_no_relu
      // Linear path: truncate accumulator to DATA_WIDTH (no activation)
      assign relu_out = acc_biased [DATA_WIDTH - 1 : 0];
    end
  endgenerate

  mac_unit #(
    .DATA_WIDTH     (DATA_WIDTH),
    .ACC_WIDTH      (ACC_WIDTH)
  ) mac_unit_01 (
    .clk            (clk),
    .rst_n          (rst_n),

    .en             (mac_en),
    .clear          (mac_clear),
    
    .data_in        (mac_data),
    .weight         (weight_rd),
    
    .acc_out        (acc_out),
    .valid          ()
  );

  always_ff @(posedge clk) begin
    weight_rd         <= weight_mem [weight_addr];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt             <= 0;
      weight_addr     <= 0;

      out_cnt         <= 0;
      in_cnt          <= 0;
      k_cnt           <= 0;

      mac_en          <= 0;
      mac_clear       <= 0;
      mac_data        <= 0;

      valid_out       <= 0;
      data_out        <= 0;
    
    end else begin
      mac_en          <= 0;
      mac_clear       <= 0;
      valid_out       <= 0;

      if (cnt == 0) begin
        // IDLE
        if (en) begin
          // Latch dilated taps before shift register advances
          // all_taps layout: channel i, delay-tap d → bits [(i*(DEPTH+1)+d)*DW +: DW]
          for (i = 0; i < IN_CHANNELS; i = i + 1) begin
            for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
              tap_latch [i][j] <= $signed(all_taps [(i * (DEPTH + 1) + j * DILATION) * DATA_WIDTH +: DATA_WIDTH]);
            end
          end

          mac_clear   <= 1;          // Zero accumulator
          weight_addr <= 0;          // Pre-fetch w[0]: ready next cycle
          cnt         <= 1;

          out_cnt     <= 0;
          in_cnt      <= 0;
          k_cnt       <= 0;

        end

      end else if (cnt <= STEPS_PER_OUT) begin
        // ACCUMULATE : step through IN_CH * K taps for current output channel
        mac_en        <= 1;
        mac_data      <= tap_latch [in_cnt][k_cnt];

        // Advance sub-counters for next step
        if (k_cnt < KERNEL_SIZE - 1) begin
          k_cnt       <= k_cnt + 1;
        end else begin
          k_cnt       <= 0;
          in_cnt      <= in_cnt + 1;
        end

        // pre-fetch next weight (not needed on final accum step)
        if (cnt < STEPS_PER_OUT) begin
          weight_addr <= out_cnt * STEPS_PER_OUT + cnt;
        end

        cnt           <= cnt + 1;

      end else if (cnt == CNT_SETTLE) begin
        // SETTLE : final MAC product lands in acc_out after this edge
        cnt           <= cnt + 1;

      end else begin
        // SAVE (cnt == CNT_SAVE)
        data_out [out_cnt * DATA_WIDTH +: DATA_WIDTH] <= relu_out;

        if (out_cnt < OUT_CHANNELS - 1) begin
          // More output channels : loop back to ACCUM
          out_cnt     <= out_cnt + 1;
          in_cnt      <= 0;
          k_cnt       <= 0;
          
          mac_clear   <= 1;
          weight_addr <= (out_cnt + 1) * STEPS_PER_OUT;
          cnt         <= 1;
        
        end else begin
          // All output channels done
          valid_out   <= 1;
          out_cnt     <= 0;
          cnt         <= 0;
        end
      
      end
    
    end
  
  end

endmodule
