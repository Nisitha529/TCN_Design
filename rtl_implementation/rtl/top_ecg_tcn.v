// ecg_tcn_top — full ECG TCN inference pipeline
//
// Chain: Block0(1→4,dil=1) → Block1(4→4,dil=2) →
//        Block2(4→8,dil=4) → Block3(8→8,dil=8)
//        → GAP(WINDOW_LEN) → Linear Head(8→N_CLASSES)
//
// All arithmetic Q8.8 (FRAC_BITS=8, SCALE=256).
// WINDOW_LEN must be a power of 2; set LOG_WINDOW = log2(WINDOW_LEN).
// The user must space en pulses at least MAX_BLOCK_LAT=418 cycles apart
// to avoid pipeline conflicts in the block chain.
//
// Output valid_out pulses HIGH for exactly one cycle after classification.

module top_ecg_tcn #(
  parameter DATA_WIDTH = 16,
  parameter ACC_WIDTH  = 32,
  parameter FRAC_BITS  = 8,
  parameter WINDOW_LEN = 8,
  parameter LOG_WINDOW = 3,    // must equal $clog2(WINDOW_LEN)
  parameter N_CLASSES  = 3,
  parameter FEAT_DIM   = 8,    // = block3 OUT_CHANNELS

  // Weight/bias files — paths relative to simulation working directory
  parameter B0_W1 = "../weights/block0_conv1_weights.hex",
  parameter B0_B1 = "../weights/block0_conv1_bias.hex",
  parameter B0_W2 = "../weights/block0_conv2_weights.hex",
  parameter B0_B2 = "../weights/block0_conv2_bias.hex",
  parameter B0_RW = "../weights/block0_res_weights.hex",
  parameter B0_RB = "../weights/block0_res_bias.hex",

  parameter B1_W1 = "../weights/block1_conv1_weights.hex",
  parameter B1_B1 = "../weights/block1_conv1_bias.hex",
  parameter B1_W2 = "../weights/block1_conv2_weights.hex",
  parameter B1_B2 = "../weights/block1_conv2_bias.hex",

  parameter B2_W1 = "../weights/block2_conv1_weights.hex",
  parameter B2_B1 = "../weights/block2_conv1_bias.hex",
  parameter B2_W2 = "../weights/block2_conv2_weights.hex",
  parameter B2_B2 = "../weights/block2_conv2_bias.hex",
  parameter B2_RW = "../weights/block2_res_weights.hex",
  parameter B2_RB = "../weights/block2_res_bias.hex",

  parameter B3_W1 = "../weights/block3_conv1_weights.hex",
  parameter B3_B1 = "../weights/block3_conv1_bias.hex",
  parameter B3_W2 = "../weights/block3_conv2_weights.hex",
  parameter B3_B2 = "../weights/block3_conv2_bias.hex",

  parameter HEAD_W = "../weights/head_weights.hex",
  parameter HEAD_B = "../weights/head_bias.hex"
)(
  input  wire                            clk,
  input  wire                            rst_n,
  input  wire                            en,
  input  wire [DATA_WIDTH-1:0]           data_in,       // 1-channel input

  output reg  [N_CLASSES*DATA_WIDTH-1:0] class_out,
  output reg                             valid_out
);

  // ── Block chain wires ───────────────────────────────────────────────────
  wire [4*DATA_WIDTH-1:0] b0_out;
  wire [4*DATA_WIDTH-1:0] b1_out;
  wire [8*DATA_WIDTH-1:0] b2_out;
  wire [8*DATA_WIDTH-1:0] b3_out;
  wire                    b0_valid, b1_valid, b2_valid, b3_valid;

  // ── Block 0 ─────────────────────────────────────────────────────────────
  tcn_block #(
    .IN_CHANNELS (1), .OUT_CHANNELS(4),
    .KERNEL_SIZE (3), .DILATION    (1),
    .DATA_WIDTH  (DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .FRAC_BITS(FRAC_BITS),
    .HAS_RES_CONV(1),
    .WEIGHT_FILE_1(B0_W1), .BIAS_FILE_1(B0_B1),
    .WEIGHT_FILE_2(B0_W2), .BIAS_FILE_2(B0_B2),
    .RES_WEIGHT_FILE(B0_RW), .RES_BIAS_FILE(B0_RB)
  ) block0 (
    .clk(clk), .rst_n(rst_n),
    .en(en), .data_in(data_in),
    .data_out(b0_out), .valid_out(b0_valid)
  );

  // ── Block 1 ─────────────────────────────────────────────────────────────
  tcn_block #(
    .IN_CHANNELS (4), .OUT_CHANNELS(4),
    .KERNEL_SIZE (3), .DILATION    (2),
    .DATA_WIDTH  (DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .FRAC_BITS(FRAC_BITS),
    .HAS_RES_CONV(0),
    .WEIGHT_FILE_1(B1_W1), .BIAS_FILE_1(B1_B1),
    .WEIGHT_FILE_2(B1_W2), .BIAS_FILE_2(B1_B2),
    .RES_WEIGHT_FILE("dummy.hex"), .RES_BIAS_FILE("dummy.hex")
  ) block1 (
    .clk(clk), .rst_n(rst_n),
    .en(b0_valid), .data_in(b0_out),
    .data_out(b1_out), .valid_out(b1_valid)
  );

  // ── Block 2 ─────────────────────────────────────────────────────────────
  tcn_block #(
    .IN_CHANNELS (4), .OUT_CHANNELS(8),
    .KERNEL_SIZE (3), .DILATION    (4),
    .DATA_WIDTH  (DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .FRAC_BITS(FRAC_BITS),
    .HAS_RES_CONV(1),
    .WEIGHT_FILE_1(B2_W1), .BIAS_FILE_1(B2_B1),
    .WEIGHT_FILE_2(B2_W2), .BIAS_FILE_2(B2_B2),
    .RES_WEIGHT_FILE(B2_RW), .RES_BIAS_FILE(B2_RB)
  ) block2 (
    .clk(clk), .rst_n(rst_n),
    .en(b1_valid), .data_in(b1_out),
    .data_out(b2_out), .valid_out(b2_valid)
  );

  // ── Block 3 ─────────────────────────────────────────────────────────────
  tcn_block #(
    .IN_CHANNELS (8), .OUT_CHANNELS(8),
    .KERNEL_SIZE (3), .DILATION    (8),
    .DATA_WIDTH  (DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH), .FRAC_BITS(FRAC_BITS),
    .HAS_RES_CONV(0),
    .WEIGHT_FILE_1(B3_W1), .BIAS_FILE_1(B3_B1),
    .WEIGHT_FILE_2(B3_W2), .BIAS_FILE_2(B3_B2),
    .RES_WEIGHT_FILE("dummy.hex"), .RES_BIAS_FILE("dummy.hex")
  ) block3 (
    .clk(clk), .rst_n(rst_n),
    .en(b2_valid), .data_in(b2_out),
    .data_out(b3_out), .valid_out(b3_valid)
  );

  // ── GAP state machine + linear head ─────────────────────────────────────

  localparam ST_STREAM = 2'd0;   // accumulate block3 valid outputs
  localparam ST_GAP    = 2'd1;   // shift-right to get average
  localparam ST_CLASS  = 2'd2;   // register combinational head result
  localparam ST_DONE   = 2'd3;   // done (wait for reset)

  reg [1:0] state;

  // GAP accumulators (INT32) and averages (INT16)
  reg signed [ACC_WIDTH-1:0]  gap_acc [0:FEAT_DIM-1];
  reg signed [DATA_WIDTH-1:0] gap_avg [0:FEAT_DIM-1];

  reg [$clog2(WINDOW_LEN):0] gap_cnt;   // counts block3 valid outputs

  // Head weights / biases
  reg signed [DATA_WIDTH-1:0] head_w [0:N_CLASSES*FEAT_DIM-1];
  reg signed [DATA_WIDTH-1:0] head_b [0:N_CLASSES-1];

  initial begin
    $readmemh(HEAD_W, head_w);
    $readmemh(HEAD_B, head_b);
  end

  // Combinational linear head: evaluated whenever gap_avg or head_w changes
  // y[j] = (sum_i gap_avg[i]*head_w[j*FEAT_DIM+i]) >>> FRAC_BITS + head_b[j]
  reg signed [ACC_WIDTH-1:0] head_result [0:N_CLASSES-1];
  integer hj, hi;
  always @(*) begin
    for (hj = 0; hj < N_CLASSES; hj = hj + 1) begin
      head_result[hj] = {ACC_WIDTH{1'b0}};
      for (hi = 0; hi < FEAT_DIM; hi = hi + 1) begin
        head_result[hj] = head_result[hj] +
          $signed(gap_avg[hi]) * $signed(head_w[hj * FEAT_DIM + hi]);
      end
      head_result[hj] = ($signed(head_result[hj]) >>> FRAC_BITS) +
        {{(ACC_WIDTH - DATA_WIDTH){head_b[hj][DATA_WIDTH-1]}}, head_b[hj]};
    end
  end

  // Registered state machine
  integer gi;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_STREAM;
      gap_cnt   <= 0;
      valid_out <= 0;
      class_out <= 0;
      for (gi = 0; gi < FEAT_DIM; gi = gi + 1) begin
        gap_acc[gi] <= 0;
        gap_avg[gi] <= 0;
      end

    end else begin
      valid_out <= 0;   // default: pulse high for one cycle in ST_CLASS

      case (state)

        ST_STREAM: begin
          if (b3_valid) begin
            for (gi = 0; gi < FEAT_DIM; gi = gi + 1) begin
              gap_acc[gi] <= gap_acc[gi] +
                $signed(b3_out[gi * DATA_WIDTH +: DATA_WIDTH]);
            end
            gap_cnt <= gap_cnt + 1;
            if (gap_cnt == WINDOW_LEN - 1)
              state <= ST_GAP;
          end
        end

        ST_GAP: begin
          // gap_acc now holds the full WINDOW_LEN-sample sum (registered from last ST_STREAM)
          for (gi = 0; gi < FEAT_DIM; gi = gi + 1)
            gap_avg[gi] <= $signed(gap_acc[gi]) >>> LOG_WINDOW;
          state <= ST_CLASS;
        end

        ST_CLASS: begin
          // head_result is combinational from gap_avg (valid since ST_GAP registered it)
          class_out[0*DATA_WIDTH +: DATA_WIDTH] <= head_result[0][DATA_WIDTH-1:0];
          class_out[1*DATA_WIDTH +: DATA_WIDTH] <= head_result[1][DATA_WIDTH-1:0];
          class_out[2*DATA_WIDTH +: DATA_WIDTH] <= head_result[2][DATA_WIDTH-1:0];
          valid_out <= 1;
          state     <= ST_DONE;
        end

        ST_DONE: begin
          // stay until reset
        end

      endcase
    end
  end

endmodule
