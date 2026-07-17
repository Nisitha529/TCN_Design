module tcn_block #(
  parameter IN_CHANNELS     = 1,
  parameter OUT_CHANNELS    = 1,

  parameter KERNEL_SIZE     = 3,
  parameter DILATION        = 1,

  parameter DATA_WIDTH      = 16,
  parameter ACC_WIDTH       = 32,

  // Fractional bits for Q8.8 fixed-point (pass 8 with exported model weights)
  parameter FRAC_BITS        = 0,

  // Set 1 when IN_CHANNELS != OUT_CHANNELS; drives a 1x1 residual conv
  parameter HAS_RES_CONV    = 0,

  parameter WEIGHT_FILE_1   = "w1.hex",
  parameter BIAS_FILE_1     = "b1.hex",
  parameter WEIGHT_FILE_2   = "w2.hex",
  parameter BIAS_FILE_2     = "b2.hex",
  parameter RES_WEIGHT_FILE = "res_w.hex",
  parameter RES_BIAS_FILE   = "res_b.hex"
)(
  input  wire                                     clk,
  input  wire                                     rst_n,

  input  wire                                     en,
  input  wire [IN_CHANNELS  * DATA_WIDTH - 1 : 0] data_in,

  output reg  [OUT_CHANNELS * DATA_WIDTH - 1 : 0] data_out,
  output reg                                      valid_out
);

  // causal_conv1d latency = OUT_CH * (IN_CH * K + 2) cycles from en to valid_out
  localparam CONV1_LAT  = OUT_CHANNELS * (IN_CHANNELS  * KERNEL_SIZE + 2);
  localparam CONV2_LAT  = OUT_CHANNELS * (OUT_CHANNELS * KERNEL_SIZE + 2);
  // conv1_valid is registered so conv2 sees "en"able one cycle after conv1 outputs
  localparam MAIN_LAT   = CONV1_LAT + CONV2_LAT + 1;

  // residual 1x1 (K = 1) : OUT_CH * (IN_CH + 2) cycles; 0 when HAS_RES_CONV = 0
  localparam RES_LAT    = HAS_RES_CONV ? OUT_CHANNELS * (IN_CHANNELS + 2) : 0;

  // RES_DELAY derivation:
  // The output register samples relu_out at posedge MAIN_LAT+1 (one cycle after
  // conv2_valid).  res_sr[RES_DELAY-1] must contain the valid residual at that moment.
  //
  // Identity (HAS_RES_CONV=0): res_feed=data_in is combinational; res_sr[0]=x after
  //   posedge X. Need res_sr[MAIN_LAT] at posedge MAIN_LAT → RES_DELAY = MAIN_LAT + 1.
  //
  // 1×1 conv (HAS_RES_CONV=1): res_conv.data_out[last_ch] is set via non-blocking at
  //   posedge X+RES_LAT, so res_sr[0] first holds the fully-valid value after
  //   posedge X+RES_LAT+1.  Need RES_DELAY-1 more shifts to reach posedge MAIN_LAT:
  //   RES_LAT+1+(RES_DELAY-1) = MAIN_LAT → RES_DELAY = MAIN_LAT - RES_LAT.
  localparam RES_DELAY  = HAS_RES_CONV ? (MAIN_LAT - RES_LAT) : (MAIN_LAT + 1);

  genvar                                   gch;

  integer                                  jj;

  // Delay res_feed by RES_DELAY cycles so it aligns with the output register
  // (which captures 1 cycle after conv2_valid, i.e., MAIN_LAT+1 cycles total)
  reg  [OUT_CHANNELS * DATA_WIDTH - 1 : 0] res_sr       [0 : RES_DELAY - 1];

  wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] res_path_out = res_sr [RES_DELAY - 1]; 

  // Conv1 : IN_CH : OUT_CH
  wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] conv1_out;
  wire                                     conv1_valid;

  // Conv2 : OUT_CH : OUT_CH, chained from conv1_valid.
  wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] conv2_out;
  wire                                     conv2_valid;

  // Residual path
  // res_feed : what gets loaded into the delay shift register every clock
  wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] res_feed;

  // Per-channel saturating add + ReLU (combinational)
  wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] relu_out;

  generate
    if (HAS_RES_CONV) begin : gen_res_1x1
      // 1 × 1 causal_conv1d: IN_CH : OUT_CH, latency = RES_LAT cycles
      wire [OUT_CHANNELS * DATA_WIDTH - 1 : 0] res_conv_out;

      causal_conv1d #(
        .IN_CHANNELS  (IN_CHANNELS),
        .OUT_CHANNELS (OUT_CHANNELS),

        .KERNEL_SIZE  (1),
        .DILATION     (1),

        .DATA_WIDTH   (DATA_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),

        .WEIGHT_FILE  (RES_WEIGHT_FILE),
        .BIAS_FILE    (RES_BIAS_FILE),

        .FRAC_BITS    (FRAC_BITS),
        .APPLY_RELU   (0)
      ) res_conv (
        .clk          (clk),
        .rst_n        (rst_n),

        .en           (en),
        .data_in      (data_in),

        .data_out     (res_conv_out),
        .valid_out    ()
      );

      assign res_feed = res_conv_out;

    end else begin : gen_res_id
      // Identity : IN_CHANNELS must equal OUT_CHANNELS
      assign res_feed = data_in;
    end
  endgenerate

  generate
    for (gch = 0; gch < OUT_CHANNELS; gch = gch + 1) begin : gen_ch
      wire signed [DATA_WIDTH - 1 : 0] ch_conv2;
      wire signed [DATA_WIDTH - 1 : 0] ch_res;
      wire signed [DATA_WIDTH - 1 : 0] ch_sum;
      wire signed [DATA_WIDTH - 1 : 0] ch_relu;

      assign ch_conv2 = $signed(conv2_out    [gch * DATA_WIDTH +: DATA_WIDTH]);
      assign ch_res   = $signed(res_path_out [gch * DATA_WIDTH +: DATA_WIDTH]);

      adder_sat #(
        .DATA_WIDTH    (DATA_WIDTH)
      ) add_i (
        .a             (ch_conv2),
        .b             (ch_res),

        .result        (ch_sum)
      );

      relu #(
        .DATA_WIDTH    (DATA_WIDTH)
      ) relu_i (
        .data_in       (ch_sum),

        .data_out      (ch_relu)
      );

      assign relu_out[gch * DATA_WIDTH +: DATA_WIDTH] = ch_relu;
    end
  endgenerate

  causal_conv1d #(
    .IN_CHANNELS      (IN_CHANNELS),
    .OUT_CHANNELS     (OUT_CHANNELS),

    .KERNEL_SIZE      (KERNEL_SIZE),
    .DILATION         (DILATION),

    .DATA_WIDTH       (DATA_WIDTH),
    .ACC_WIDTH        (ACC_WIDTH),

    .WEIGHT_FILE      (WEIGHT_FILE_1),
    .BIAS_FILE        (BIAS_FILE_1),

    .FRAC_BITS        (FRAC_BITS)
  ) conv1 (
    .clk              (clk),
    .rst_n            (rst_n),

    .en               (en),
    .data_in          (data_in),

    .data_out         (conv1_out),
    .valid_out        (conv1_valid)
  );

  causal_conv1d #(
    .IN_CHANNELS      (OUT_CHANNELS),
    .OUT_CHANNELS     (OUT_CHANNELS),

    .KERNEL_SIZE      (KERNEL_SIZE),
    .DILATION         (DILATION),

    .DATA_WIDTH       (DATA_WIDTH),
    .ACC_WIDTH        (ACC_WIDTH),

    .WEIGHT_FILE      (WEIGHT_FILE_2),
    .BIAS_FILE        (BIAS_FILE_2),

    .FRAC_BITS        (FRAC_BITS)
  ) conv2 (
    .clk              (clk),
    .rst_n            (rst_n),

    .en               (conv1_valid),
    .data_in          (conv1_out),

    .data_out         (conv2_out),
    .valid_out        (conv2_valid)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (jj = 0; jj < RES_DELAY; jj = jj + 1) begin
        res_sr [jj] <= 0;
      end

    end else begin
      res_sr [0]    <= res_feed;

      for (jj = 1; jj < RES_DELAY; jj = jj + 1) begin
        res_sr [jj] <= res_sr [jj - 1];
      end

    end
  end



  // ── Output register : 1 cycle after conv2_valid ──────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out  <= 0;
      valid_out <= 0;
    end else begin
      valid_out <= conv2_valid;
      if (conv2_valid)
        data_out <= relu_out;
    end
  end

endmodule
