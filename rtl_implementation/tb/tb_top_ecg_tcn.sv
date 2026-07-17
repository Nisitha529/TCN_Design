`timescale 1ns/1ps

// ECG TCN end-to-end testbench — 4 test cases covering all 3 output classes
//
// Test cases (WINDOW_LEN=8, Q8.8 integers):
//   TC0  const_0    [0]*8           → pred class 0  [  146,  -724,  -241]
//   TC1  const_256  [256]*8         → pred class 1  [-5486, 14907,-16111]
//   TC2  const_n512 [-512]*8        → pred class 2  [  523, -1830,   546]
//   TC3  alt_256    [±256 alt.]*8   → pred class 1  [-1983,  4863, -4518]
//
// Expected values from gen_full_chain.py (Q8.8 integer arithmetic).
// DUT is fully reset between test cases to flush all pipeline state.
// Samples within each test case are spaced MIN_SPACING=418 cycles apart
// (= block3 TOTAL_LAT, the pipeline bottleneck).

module tb_top_ecg_tcn;

  localparam DATA_WIDTH  = 16;
  localparam ACC_WIDTH   = 32;
  localparam FRAC_BITS   = 8;
  localparam WINDOW_LEN  = 8;
  localparam LOG_WINDOW  = 3;
  localparam N_CLASSES   = 3;
  localparam FEAT_DIM    = 8;
  localparam N_TESTS     = 4;

  localparam CLK_PERIOD  = 10;
  localparam MIN_SPACING = 418;   // cycles between en pulses (block3 bottleneck)
  localparam TIMEOUT     = 5000;  // per-test-case timeout in cycles

  logic                              clk;
  logic                              rst_n;
  logic                              en;
  logic [DATA_WIDTH-1:0]             data_in;
  wire  [N_CLASSES*DATA_WIDTH-1:0]   class_out;
  wire                               valid_out;

  wire signed [DATA_WIDTH-1:0] c0 = $signed(class_out[0*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] c1 = $signed(class_out[1*DATA_WIDTH +: DATA_WIDTH]);
  wire signed [DATA_WIDTH-1:0] c2 = $signed(class_out[2*DATA_WIDTH +: DATA_WIDTH]);

  top_ecg_tcn #(
    .DATA_WIDTH (DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH),
    .FRAC_BITS  (FRAC_BITS),  .WINDOW_LEN(WINDOW_LEN),
    .LOG_WINDOW (LOG_WINDOW), .N_CLASSES(N_CLASSES), .FEAT_DIM(FEAT_DIM),

    .B0_W1("../weights/block0_conv1_weights.hex"),
    .B0_B1("../weights/block0_conv1_bias.hex"),
    .B0_W2("../weights/block0_conv2_weights.hex"),
    .B0_B2("../weights/block0_conv2_bias.hex"),
    .B0_RW("../weights/block0_res_weights.hex"),
    .B0_RB("../weights/block0_res_bias.hex"),

    .B1_W1("../weights/block1_conv1_weights.hex"),
    .B1_B1("../weights/block1_conv1_bias.hex"),
    .B1_W2("../weights/block1_conv2_weights.hex"),
    .B1_B2("../weights/block1_conv2_bias.hex"),

    .B2_W1("../weights/block2_conv1_weights.hex"),
    .B2_B1("../weights/block2_conv1_bias.hex"),
    .B2_W2("../weights/block2_conv2_weights.hex"),
    .B2_B2("../weights/block2_conv2_bias.hex"),
    .B2_RW("../weights/block2_res_weights.hex"),
    .B2_RB("../weights/block2_res_bias.hex"),

    .B3_W1("../weights/block3_conv1_weights.hex"),
    .B3_B1("../weights/block3_conv1_bias.hex"),
    .B3_W2("../weights/block3_conv2_weights.hex"),
    .B3_B2("../weights/block3_conv2_bias.hex"),

    .HEAD_W("../weights/head_weights.hex"),
    .HEAD_B("../weights/head_bias.hex")
  ) dut (
    .clk(clk), .rst_n(rst_n), .en(en), .data_in(data_in),
    .class_out(class_out), .valid_out(valid_out)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ── Test-case tables ───────────────────────────────────────────────────────
  logic signed [DATA_WIDTH-1:0] test_in  [0:N_TESTS-1][0:WINDOW_LEN-1];
  logic signed [DATA_WIDTH-1:0] test_exp [0:N_TESTS-1][0:N_CLASSES-1];
  integer                        test_pred[0:N_TESTS-1];

  // ── Loop / status variables ──────────────────────────────────────────────
  integer pass_cnt, fail_cnt;
  integer tc, s, t;
  integer pred_got, scores_ok, got_valid;

  // ── Tasks ────────────────────────────────────────────────────────────────

  task send_sample(input signed [DATA_WIDTH-1:0] x);
    data_in = x;
    en      = 1;
    @(posedge clk); #1;
    en      = 0;
    data_in = 0;
  endtask

  task wait_cycles(input integer n);
    integer k;
    for (k = 0; k < n; k = k + 1) @(posedge clk);
    #1;
  endtask

  task reset_dut;
    rst_n   = 0;
    en      = 0;
    data_in = 0;
    repeat(4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;
  endtask

  // ── Main stimulus ─────────────────────────────────────────────────────────

  initial begin
    // TC0: all-zero input → class 0
    for (s = 0; s < WINDOW_LEN; s = s + 1) test_in[0][s] = 16'sd0;
    test_exp[0][0] = 16'sd146;    test_exp[0][1] = -16'sd724;  test_exp[0][2] = -16'sd241;
    test_pred[0]   = 0;

    // TC1: constant 1.0 (256 Q8.8) → class 1
    for (s = 0; s < WINDOW_LEN; s = s + 1) test_in[1][s] = 16'sd256;
    test_exp[1][0] = -16'sd5486;  test_exp[1][1] = 16'sd14907; test_exp[1][2] = -16'sd16111;
    test_pred[1]   = 1;

    // TC2: constant -2.0 (-512 Q8.8) → class 2
    for (s = 0; s < WINDOW_LEN; s = s + 1) test_in[2][s] = -16'sd512;
    test_exp[2][0] = 16'sd523;    test_exp[2][1] = -16'sd1830; test_exp[2][2] = 16'sd546;
    test_pred[2]   = 2;

    // TC3: alternating ±1.0 → class 1
    for (s = 0; s < WINDOW_LEN; s = s + 1)
      test_in[3][s] = (s % 2 == 0) ? 16'sd256 : -16'sd256;
    test_exp[3][0] = -16'sd1983;  test_exp[3][1] = 16'sd4863;  test_exp[3][2] = -16'sd4518;
    test_pred[3]   = 1;

    pass_cnt = 0;
    fail_cnt = 0;

    $display("ECG TCN end-to-end — %0d test cases (WINDOW_LEN=%0d MIN_SPACING=%0d)",
             N_TESTS, WINDOW_LEN, MIN_SPACING);
    $display("----------------------------------------------------------------------");

    for (tc = 0; tc < N_TESTS; tc = tc + 1) begin

      // ── Reset DUT to flush all pipeline shift-register state ──────────────
      reset_dut;

      // ── Feed WINDOW_LEN samples spaced MIN_SPACING cycles apart ───────────
      for (s = 0; s < WINDOW_LEN; s = s + 1) begin
        send_sample(test_in[tc][s]);
        if (s < WINDOW_LEN - 1) wait_cycles(MIN_SPACING - 1);
      end

      // ── Wait for valid_out (with timeout) ─────────────────────────────────
      got_valid = 0;
      begin : wait_valid
        for (t = 0; t < TIMEOUT; t = t + 1) begin
          @(posedge clk); #1;
          if (valid_out) begin
            got_valid = 1;
            disable wait_valid;
          end
        end
      end

      if (got_valid) begin
        // argmax
        if      (c0 >= c1 && c0 >= c2) pred_got = 0;
        else if (c1 >= c0 && c1 >= c2) pred_got = 1;
        else                            pred_got = 2;

        scores_ok = (c0 === test_exp[tc][0] &&
                     c1 === test_exp[tc][1] &&
                     c2 === test_exp[tc][2]);

        if (scores_ok && pred_got == test_pred[tc]) begin
          $display("TC%0d  got=[%6d,%6d,%6d]  exp=[%6d,%6d,%6d]  class%0d  PASS",
                   tc, c0, c1, c2,
                   test_exp[tc][0], test_exp[tc][1], test_exp[tc][2],
                   pred_got);
          pass_cnt = pass_cnt + 1;
        end else begin
          if (!scores_ok)
            $display("TC%0d  got=[%6d,%6d,%6d]  exp=[%6d,%6d,%6d]  class%0d  FAIL (score mismatch)",
                     tc, c0, c1, c2,
                     test_exp[tc][0], test_exp[tc][1], test_exp[tc][2],
                     pred_got);
          else
            $display("TC%0d  got=[%6d,%6d,%6d]  exp=[%6d,%6d,%6d]  pred=%0d exp=%0d  FAIL (wrong class)",
                     tc, c0, c1, c2,
                     test_exp[tc][0], test_exp[tc][1], test_exp[tc][2],
                     pred_got, test_pred[tc]);
          fail_cnt = fail_cnt + 1;
        end
      end else begin
        $display("TC%0d  TIMEOUT after %0d cycles", tc, TIMEOUT);
        fail_cnt = fail_cnt + 1;
      end

    end // for tc

    $display("----------------------------------------------------------------------");
    $display("Results: %0d/%0d PASS   %0d FAIL", pass_cnt, N_TESTS, fail_cnt);
    $finish;
  end

endmodule
