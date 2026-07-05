`timescale 1ns/1ps

module tb_shift_reg;

  parameter DATA_WIDTH = 16;
  parameter DEPTH      = 4;

  parameter CLK_PERIOD = 10;

  logic                             clk;
  logic                             rst_n;

  logic                             en;
  logic signed [DATA_WIDTH - 1 : 0] data_in;

  wire  signed [DATA_WIDTH - 1 : 0] taps [0 : DEPTH];

  shift_reg #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
  ) dut_shift_reg (
    .clk        (clk),
    .rst_n      (rst_n),

    .en         (en),
    .data_in    (data_in),

    .taps       (taps)
  );

  // 10ns clock
  initial clk   = 0;

  always #(CLK_PERIOD / 2) clk = ~clk;

  // Set data_in, display taps BEFORE clock edge, then clock
  task present_and_display(input signed [DATA_WIDTH-1:0] val);
    data_in = val;
    #1;  

    $display("input=%0d : taps = %0d %0d %0d %0d %0d", val, taps[0], taps[1], taps[2], taps[3], taps[4]);
    @(posedge clk); #1;  // Clock edge: delay[] captures current data_in

  endtask

  initial begin
    $display("Shift Register Testbench (DEPTH=%0d)", DEPTH);

    // Reset
    rst_n   = 0;
    en      = 0;
    data_in = 0;
    @(posedge clk); #1;
    rst_n   = 1;
    en      = 1;

    // Feed sequence 1..4 using task (each clocks at end)
    present_and_display(16'sd1);  // taps: 1 0 0 0 0
    present_and_display(16'sd2);  // taps: 2 1 0 0 0
    present_and_display(16'sd3);  // taps: 3 2 1 0 0
    present_and_display(16'sd4);  // taps: 4 3 2 1 0

    // step 5 done manually — dilation check must happen BEFORE the clock
    data_in = 16'sd5; #1;
    $display("input=5 : taps = %0d %0d %0d %0d %0d", taps[0], taps[1], taps[2], taps[3], taps[4]);

    $display("");
    $display("dilation=2 kernel=3 reads:");
    $display("  tap[0]=%0d (t)   tap[2]=%0d (t-2)   tap[4]=%0d (t-4)", taps[0], taps[2], taps[4]);
    $display("  expected: 5, 3, 1");

    if (taps[0]==5 && taps[2]==3 && taps[4]==1) begin
      $display("PASS");
    end else begin
      $display("FAIL");
    end

    @(posedge clk); #1; 

    // Test en=0, delay[] should not shift
    $display("");
    en      = 0;
    data_in = 16'sd99; #1;

    $display("en=0 input=99 : tap[0]=%0d (combinational, follows data_in)", taps[0]);
    $display("              : tap[1]=%0d (should be 5 — held in delay[0])", taps[1]);

    if (taps[0]==99 && taps[1]==5)
      $display("PASS hold");
    else
      $display("FAIL hold");

    $display("Done");
    $finish;
  end

endmodule
