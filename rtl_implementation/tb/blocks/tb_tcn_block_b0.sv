`timescale 1ns/1ps

// TCN Block 0 testbench with real BN-folded Q8.8 weights
//
// Block config: IN_CH=1, OUT_CH=4, K=3, DIL=1, HAS_RES_CONV=1, FRAC_BITS=8
//
// Inputs are Q8.8 integers: 256 = 1.0 float
// Expected outputs computed by gen_block0_testvectors.py using the same
// integer arithmetic (right-shift by 8 after MAC).
//
// Test sequence "const_pos": x = 256 (= 1.0) repeated 5 times
// Expected outputs at t=0..4 (from Python simulation):
//   t0: [ 719, 1173, 1305,    0]
//   t1: [1822, 2237, 2006,    0]
//   t2: [1983, 2837, 1930,    0]
//   t3: [3158, 3257, 1994,    0]
//   t4: [2762, 5275, 2621,    0]
//
// Latency:
//   CONV1_LAT = OUT_CH * (IN_CH  * K + 2) = 4 * (1*3 + 2) = 20
//   CONV2_LAT = OUT_CH * (OUT_CH * K + 2) = 4 * (4*3 + 2) = 56
//   MAIN_LAT  = CONV1_LAT + 1 + CONV2_LAT = 77
//   TOTAL_LAT = MAIN_LAT + 1              = 78

module tb_tcn_block_b0;

  localparam IN_CHANNELS  = 1;
  localparam OUT_CHANNELS = 4;
  localparam KERNEL_SIZE  = 3;
  localparam DILATION     = 1;

  localparam DATA_WIDTH   = 16;
  localparam ACC_WIDTH    = 32;
  localparam FRAC_BITS    = 8;

  localparam CONV1_LAT    = OUT_CHANNELS * (IN_CHANNELS  * KERNEL_SIZE + 2);
  localparam CONV2_LAT    = OUT_CHANNELS * (OUT_CHANNELS * KERNEL_SIZE + 2);
  localparam MAIN_LAT     = CONV1_LAT + 1 + CONV2_LAT;
  localparam TOTAL_LAT    = MAIN_LAT + 1;

  localparam CLK_PERIOD   = 10;

  logic                                     clk;
  logic                                     rst_n;
  logic                                     en;
  logic [IN_CHANNELS  * DATA_WIDTH - 1 : 0] data_in;
  wire  [OUT_CHANNELS * DATA_WIDTH - 1 : 0] data_out;
  wire                                      valid_out;

  // per-channel output aliases
  wire signed [DATA_WIDTH-1:0] out_ch0 = $signed(data_out[0*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch1 = $signed(data_out[1*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch2 = $signed(data_out[2*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch3 = $signed(data_out[3*DATA_WIDTH +: DATA_WIDTH]);

  tcn_block #(
    .IN_CHANNELS    (IN_CHANNELS),
    .OUT_CHANNELS   (OUT_CHANNELS),
    .KERNEL_SIZE    (KERNEL_SIZE),
    .DILATION       (DILATION),
    .DATA_WIDTH     (DATA_WIDTH),
    .ACC_WIDTH      (ACC_WIDTH),
    .FRAC_BITS      (FRAC_BITS),
    .HAS_RES_CONV   (1),
    .WEIGHT_FILE_1  ("../../weights/block0_conv1_weights.hex"),
    .BIAS_FILE_1    ("../../weights/block0_conv1_bias.hex"),
    .WEIGHT_FILE_2  ("../../weights/block0_conv2_weights.hex"),
    .BIAS_FILE_2    ("../../weights/block0_conv2_bias.hex"),
    .RES_WEIGHT_FILE("../../weights/block0_res_weights.hex"),
    .RES_BIAS_FILE  ("../../weights/block0_res_bias.hex")
  ) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .en       (en),
    .data_in  (data_in),
    .data_out (data_out),
    .valid_out(valid_out)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  integer pass_cnt;
  integer fail_cnt;

  task apply_and_check(
    input signed [DATA_WIDTH-1:0] x,
    input signed [DATA_WIDTH-1:0] exp0,
    input signed [DATA_WIDTH-1:0] exp1,
    input signed [DATA_WIDTH-1:0] exp2,
    input signed [DATA_WIDTH-1:0] exp3
  );
    integer t;
    data_in = x;
    en      = 1;
    @(posedge clk); #1;
    en      = 0;
    data_in = 0;

    for (t = 0; t < TOTAL_LAT + 4; t = t + 1) begin
      @(posedge clk); #1;
      if (valid_out) begin
        if (out_ch0 === exp0 && out_ch1 === exp1 &&
            out_ch2 === exp2 && out_ch3 === exp3) begin
          $display("PASS  in=%0d  out=[%0d,%0d,%0d,%0d]  exp=[%0d,%0d,%0d,%0d]",
                   x, out_ch0, out_ch1, out_ch2, out_ch3,
                   exp0, exp1, exp2, exp3);
          pass_cnt = pass_cnt + 1;
        end else begin
          $display("FAIL  in=%0d  out=[%0d,%0d,%0d,%0d]  exp=[%0d,%0d,%0d,%0d]",
                   x, out_ch0, out_ch1, out_ch2, out_ch3,
                   exp0, exp1, exp2, exp3);
          fail_cnt = fail_cnt + 1;
        end
        disable apply_and_check;
      end
    end
    $display("TIMEOUT  in=%0d", x);
    fail_cnt = fail_cnt + 1;
  endtask

  initial begin
    $display("TCN Block 0 — Real Q8.8 Weights (FRAC_BITS=%0d)", FRAC_BITS);
    $display("IN=%0d OUT=%0d K=%0d DIL=%0d HAS_RES=1",
             IN_CHANNELS, OUT_CHANNELS, KERNEL_SIZE, DILATION);
    $display("CONV1_LAT=%0d  CONV2_LAT=%0d  MAIN_LAT=%0d  TOTAL=%0d",
             CONV1_LAT, CONV2_LAT, MAIN_LAT, TOTAL_LAT);
    $display("----------------------------------------");

    pass_cnt = 0;
    fail_cnt = 0;
    rst_n    = 0;
    en       = 0;
    data_in  = 0;

    repeat(2) @(posedge clk); #1;
    rst_n = 1;

    // const_pos: x = 256 (1.0 in Q8.8) × 5 samples
    // expected outputs from gen_block0_testvectors.py
    apply_and_check(16'sd256,  16'sd719,  16'sd1173, 16'sd1305, 16'sd0);
    apply_and_check(16'sd256,  16'sd1822, 16'sd2237, 16'sd2006, 16'sd0);
    apply_and_check(16'sd256,  16'sd1983, 16'sd2837, 16'sd1930, 16'sd0);
    apply_and_check(16'sd256,  16'sd3158, 16'sd3257, 16'sd1994, 16'sd0);
    apply_and_check(16'sd256,  16'sd2762, 16'sd5275, 16'sd2621, 16'sd0);

    $display("----------------------------------------");
    $display("Results: %0d PASS  %0d FAIL", pass_cnt, fail_cnt);
    $finish;
  end

endmodule
