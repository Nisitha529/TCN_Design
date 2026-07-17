`timescale 1ns/1ps

// TCN Block 3 testbench with real BN-folded Q8.8 weights
//
// Block config: IN_CH=8, OUT_CH=8, K=3, DIL=8, HAS_RES_CONV=0, FRAC_BITS=8
// Input: all 8 channels = 256 (1.0 Q8.8) for 5 samples
//
// Latency:
//   CONV1_LAT = 8*(8*3+2) = 208
//   CONV2_LAT = 8*(8*3+2) = 208
//   MAIN_LAT  = 208+1+208 = 417
//   TOTAL_LAT = 417+1     = 418

module tb_tcn_block_b3;

  localparam IN_CHANNELS  = 8;
  localparam OUT_CHANNELS = 8;
  localparam KERNEL_SIZE  = 3;
  localparam DILATION     = 8;

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

  wire signed [DATA_WIDTH-1:0] out_ch0 = $signed(data_out[0*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch1 = $signed(data_out[1*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch2 = $signed(data_out[2*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch3 = $signed(data_out[3*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch4 = $signed(data_out[4*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch5 = $signed(data_out[5*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch6 = $signed(data_out[6*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] out_ch7 = $signed(data_out[7*DATA_WIDTH +: DATA_WIDTH]);

  tcn_block #(
    .IN_CHANNELS    (IN_CHANNELS),
    .OUT_CHANNELS   (OUT_CHANNELS),
    .KERNEL_SIZE    (KERNEL_SIZE),
    .DILATION       (DILATION),
    .DATA_WIDTH     (DATA_WIDTH),
    .ACC_WIDTH      (ACC_WIDTH),
    .FRAC_BITS      (FRAC_BITS),
    .HAS_RES_CONV   (0),
    .WEIGHT_FILE_1  ("../../weights/block3_conv1_weights.hex"),
    .BIAS_FILE_1    ("../../weights/block3_conv1_bias.hex"),
    .WEIGHT_FILE_2  ("../../weights/block3_conv2_weights.hex"),
    .BIAS_FILE_2    ("../../weights/block3_conv2_bias.hex"),
    .RES_WEIGHT_FILE("dummy_res_w.hex"),
    .RES_BIAS_FILE  ("dummy_res_b.hex")
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
    input signed [DATA_WIDTH-1:0] exp0, exp1, exp2, exp3,
    input signed [DATA_WIDTH-1:0] exp4, exp5, exp6, exp7
  );
    integer t;
    data_in = {16'sd256, 16'sd256, 16'sd256, 16'sd256,
               16'sd256, 16'sd256, 16'sd256, 16'sd256};
    en      = 1;
    @(posedge clk); #1;
    en      = 0;
    data_in = 0;

    for (t = 0; t < TOTAL_LAT + 4; t = t + 1) begin
      @(posedge clk); #1;
      if (valid_out) begin
        if (out_ch0 === exp0 && out_ch1 === exp1 &&
            out_ch2 === exp2 && out_ch3 === exp3 &&
            out_ch4 === exp4 && out_ch5 === exp5 &&
            out_ch6 === exp6 && out_ch7 === exp7) begin
          $display("PASS  out=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                   out_ch0, out_ch1, out_ch2, out_ch3,
                   out_ch4, out_ch5, out_ch6, out_ch7);
          pass_cnt = pass_cnt + 1;
        end else begin
          $display("FAIL  out=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]  exp=[%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d]",
                   out_ch0, out_ch1, out_ch2, out_ch3,
                   out_ch4, out_ch5, out_ch6, out_ch7,
                   exp0, exp1, exp2, exp3, exp4, exp5, exp6, exp7);
          fail_cnt = fail_cnt + 1;
        end
        disable apply_and_check;
      end
    end
    $display("TIMEOUT");
    fail_cnt = fail_cnt + 1;
  endtask

  initial begin
    $display("TCN Block 3 — Real Q8.8 Weights (FRAC_BITS=%0d)", FRAC_BITS);
    $display("IN=%0d OUT=%0d K=%0d DIL=%0d HAS_RES=0",
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

    // 5 constant-1.0 inputs (from gen_blocks_testvectors.py)
    apply_and_check(16'sd463, 16'sd349, 16'sd467, 16'sd363,
                    16'sd432, 16'sd342, 16'sd435, 16'sd380);
    apply_and_check(16'sd463, 16'sd349, 16'sd467, 16'sd363,
                    16'sd432, 16'sd342, 16'sd435, 16'sd380);
    apply_and_check(16'sd463, 16'sd349, 16'sd467, 16'sd363,
                    16'sd432, 16'sd342, 16'sd435, 16'sd380);
    apply_and_check(16'sd463, 16'sd349, 16'sd467, 16'sd363,
                    16'sd432, 16'sd342, 16'sd435, 16'sd380);
    apply_and_check(16'sd463, 16'sd349, 16'sd467, 16'sd363,
                    16'sd432, 16'sd342, 16'sd435, 16'sd380);

    $display("----------------------------------------");
    $display("Results: %0d PASS  %0d FAIL", pass_cnt, fail_cnt);
    $finish;
  end

endmodule
