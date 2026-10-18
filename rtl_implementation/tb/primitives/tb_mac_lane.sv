`timescale 1ns/1ps

// tb_mac_lane -- self-checking test of rtl/primitives/mac_lane.sv.
//
// A reference model keeps each running sum as a 64-bit integer and compares
// its low ACC_W bits (two's complement, as the hardware wraps) with `acc` on
// every valid_out cycle.
//
//   L1  single products at the corners: (-32768)^2, (-32768)*32767, 0, 1*-1
//   L2  random sums of 1..30 taps, back to back, `first` starting each one
//       (no clear cycle between sums -- the point of load-or-accumulate)
//   L3  idle cycles inside and between sums: acc must hold while valid is low
//   L4  wrap: a long sum of maximum products overflows ACC_W exactly as
//       two's complement says (the golden model never lets real data get here;
//       this pins what the hardware does if it ever did)
//   L5  synchronous reset clears the valid pipeline

module tb_mac_lane;

  localparam DW = 16, ACC_W = 32;

  logic clk = 0, rst = 1, valid_in = 0, first = 0;
  logic signed [DW - 1 : 0] a = 0, b = 0;
  wire  signed [ACC_W - 1 : 0] acc;
  wire  valid_out;
  always #2 clk = ~clk;

  mac_lane #(.DW(DW), .ACC_W(ACC_W)) dut (
    .clk(clk), .rst(rst), .valid_in(valid_in), .first(first), .a(a), .b(b),
    .acc(acc), .valid_out(valid_out));

  int pass_cnt = 0, fail_cnt = 0;
  task automatic chk(input string name, input logic cond);
    if (cond) begin $display("    [PASS] %s", name); pass_cnt++; end
    else      begin $display("    [FAIL] %s", name); fail_cnt++; end
  endtask

  // reference: expected acc after each accepted tap, in order
  longint ref_sum = 0;
  logic signed [ACC_W - 1 : 0] expq [$];
  int n_checked = 0, n_bad = 0;
  int n_before;

  always @(posedge clk) begin
    if (valid_out) begin
      logic signed [ACC_W - 1 : 0] e;
      if (expq.size() == 0) n_bad++;
      else begin
        e = expq.pop_front();
        if (acc !== e) begin
          if (n_bad < 5) $display("    mismatch: acc=%0d expected %0d", acc, e);
          n_bad++;
        end
      end
      n_checked++;
    end
  end

  task automatic tap(input logic signed [DW - 1 : 0] x, input logic signed [DW - 1 : 0] w, input bit f);
    @(negedge clk);
    a = x; b = w; first = f; valid_in = 1;
    if (f) ref_sum = 0;
    ref_sum += longint'(x) * longint'(w);
    expq.push_back(ref_sum[ACC_W - 1 : 0]);
    @(negedge clk);
    valid_in = 0; first = 0;
  endtask

  // back-to-back taps (no idle cycle between them)
  task automatic sum_burst(input int len);
    for (int j = 0; j < len; j++) begin
      logic signed [DW - 1 : 0] x, w;
      x = $urandom; w = $urandom;
      @(negedge clk);
      a = x; b = w; first = (j == 0); valid_in = 1;
      if (j == 0) ref_sum = 0;
      ref_sum += longint'(x) * longint'(w);
      expq.push_back(ref_sum[ACC_W - 1 : 0]);
    end
    @(negedge clk); valid_in = 0; first = 0;
  endtask

  task automatic drain;
    repeat (4) @(posedge clk);
  endtask

  initial begin
    $display("\n================================================================");
    $display("  mac_lane -- DW=%0d ACC_W=%0d", DW, ACC_W);
    $display("================================================================");
    repeat (3) @(posedge clk); @(negedge clk); rst = 0;

    $display("\n== L1: corner products ==");
    tap(-16'sd32768, -16'sd32768, 1);
    tap(-16'sd32768,  16'sd32767, 1);
    tap( 16'sd0,      16'sd12345, 1);
    tap( 16'sd1,     -16'sd1,     1);
    drain;
    chk("L1: (-32768)^2, (-32768)*32767, 0, -1 all exact", n_checked == 4 && n_bad == 0);

    $display("\n== L2: 300 random sums, back to back ==");
    for (int s = 0; s < 300; s++) sum_burst($urandom_range(1, 30));
    drain;
    chk("L2: every partial sum exact", n_bad == 0 && expq.size() == 0);

    $display("\n== L3: idle cycles inside and between sums ==");
    begin
      n_before = n_checked;
      tap(16'sd100, 16'sd200, 1);
      repeat (5) @(posedge clk);                    // idle inside the sum
      tap(16'sd3, 16'sd4, 0);
      repeat (3) @(posedge clk);
      tap(-16'sd7, 16'sd9, 0);
      drain;
      chk("L3: sum continues across idle cycles (100*200 + 3*4 - 7*9)",
          n_checked == n_before + 3 && n_bad == 0 && acc == 20000 + 12 - 63);
      repeat (6) @(posedge clk);
      chk("L3: acc holds while valid is low", acc == 20000 + 12 - 63);
    end

    $display("\n== L4: overflow wraps as two's complement ==");
    begin
      for (int j = 0; j < 4; j++) tap(-16'sd32768, -16'sd32768, j == 0);   // 4 * 2^30 = 2^32
      drain;
      chk("L4: 4 x 2^30 wraps to 0 in 32 bits", acc == 0 && n_bad == 0);
    end

    $display("\n== L5: synchronous reset clears the valid pipeline ==");
    begin
      n_before = n_checked;
      @(negedge clk); a = 5; b = 5; first = 1; valid_in = 1; rst = 1;
      @(negedge clk); valid_in = 0; first = 0;
      repeat (3) @(posedge clk); @(negedge clk); rst = 0;
      drain;
      chk("L5: a tap presented during reset produces no valid_out", n_checked == n_before);
    end

    $display("\n================================================================");
    $display("  Results: %0d passed, %0d failed  (total %0d)  [%0d sums checked]",
             pass_cnt, fail_cnt, pass_cnt + fail_cnt, n_checked);
    $display("================================================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else               $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #2000000; $display("[TIMEOUT]"); $finish; end

endmodule
