module causal_conv1d #(
  parameter KERNEL_SIZE = 3,
  parameter DILATION    = 1,
  parameter DATA_WIDTH  = 16,
  parameter ACC_WIDTH   = 32,
  parameter WEIGHT_FILE = "weights.hex"
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire signed [DATA_WIDTH - 1 : 0] data_in,

  output reg  signed [DATA_WIDTH - 1 : 0] data_out,
  output reg                              valid_out
);

  localparam DEPTH      = (KERNEL_SIZE - 1) * DILATION;
  localparam ADDR_W     = $clog2(KERNEL_SIZE);

  localparam CNT_SETTLE = KERNEL_SIZE + 1;
  localparam CNT_MAX    = KERNEL_SIZE + 2;
  localparam CNT_W      = $clog2(CNT_MAX + 1) + 1;

  reg signed  [DATA_WIDTH - 1 : 0] weight_mem   [0 : KERNEL_SIZE - 1];
  reg signed  [DATA_WIDTH - 1 : 0] weight_rd;
  reg         [ADDR_W - 1 : 0]     weight_addr;

  reg                              mac_en;
  reg                              mac_clear;
  reg  signed [DATA_WIDTH - 1 : 0] mac_data;

  reg         [CNT_W - 1 : 0]      cnt;
  reg signed  [DATA_WIDTH - 1 : 0] tap_latch    [0 : KERNEL_SIZE - 1];

  wire signed [DATA_WIDTH - 1 : 0] relu_out;
  
  wire signed [ACC_WIDTH - 1 : 0]  acc_out;

  wire signed [DATA_WIDTH - 1 : 0] taps         [0 : DEPTH];

  integer k;

  initial begin 
    $readmemh   (WEIGHT_FILE, weight_mem);
  end


  shift_reg #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
  ) shift_reg_01 (
    .clk        (clk),
    .rst_n      (rst_n),

    .en         (en),
    .data_in    (data_in),
    
    .taps       (taps)
  );

  mac_unit #(
    .DATA_WIDTH (DATA_WIDTH),
    .ACC_WIDTH  (ACC_WIDTH)
  ) mac_unit_01 (
    .clk        (clk),
    .rst_n      (rst_n),

    .en         (mac_en),
    .clear      (mac_clear),
    
    .data_in    (mac_data),
    .weight     (weight_rd),
    
    .acc_out    (acc_out),
    .valid      ()
  );

  relu #(
    .DATA_WIDTH (DATA_WIDTH)
  ) relu_01 (
    .data_in    (acc_out [DATA_WIDTH - 1 : 0]),
    .data_out   (relu_out)
  );

  always_ff @(posedge clk) begin
    weight_rd <= weight_mem [weight_addr];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt         <= 0;
      weight_addr <= 0;

      mac_en      <= 0;
      mac_clear   <= 0;
      mac_data    <= 0;

      valid_out   <= 0;
      data_out    <= 0;
    
    end else begin
      mac_en      <= 0;
      mac_clear   <= 0;
      valid_out   <= 0;

      if (cnt == 0) begin
        // IDLE
        if (en) begin
          // Latch dilated taps before shift register advances
          for (k = 0; k < KERNEL_SIZE; k = k + 1) begin
            tap_latch [k] <= taps [k * DILATION];
          end

          mac_clear   <= 1;          // Zero accumulator
          weight_addr <= 0;          // Pre-fetch w[0]: ready next cycle
          cnt         <= 1;

        end

      end else if (cnt <= KERNEL_SIZE) begin
        // ACCUMULATE
        // weight_rd = w[cnt-1]  (presented last cycle, 1-cycle BRAM latency)
        mac_en        <= 1;
        mac_data      <= tap_latch [cnt-1];

        // Pre-fetch next weight (no pre-fetch on final tap)
        if (cnt < KERNEL_SIZE) begin
          weight_addr <= cnt;
        end

        cnt           <= cnt + 1;

      end else if (cnt == CNT_SETTLE) begin
        // SETTLE — final MAC accumulation happened last edge, wait one cycle
        cnt           <= cnt + 1;

      end else begin
        // OUTPUT (cnt == KERNEL_SIZE+2)
        data_out      <= relu_out;
        valid_out     <= 1;
        cnt           <= 0;
      end
    end
  end

endmodule
