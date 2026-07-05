`timescale 1ns/1ps

module tb_mac_unit;

  parameter DATA_WIDTH = 16;
  parameter ACC_WIDTH  = 32;
  
  parameter CLK_PERIOD = 10;

  logic                             clk;
  logic                             rst_n;

  logic                             en;
  logic                             clear;

  logic signed [DATA_WIDTH - 1 : 0] data_in;
  logic signed [DATA_WIDTH - 1 : 0] weight;
  
  wire  signed [ACC_WIDTH - 1 : 0]  acc_out;
  wire                              valid;

  mac_unit #(
    .DATA_WIDTH (DATA_WIDTH),
    .ACC_WIDTH  (ACC_WIDTH)
  ) dut_mac_unit (
    .clk        (clk),
    .rst_n      (rst_n),

    .en         (en),
    .clear      (clear),

    .data_in    (data_in),
    .weight     (weight),

    .acc_out    (acc_out),
    .valid      (valid)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // Clock one cycle with given inputs
  task apply(
    input signed [DATA_WIDTH - 1 : 0] d,
    input signed [DATA_WIDTH - 1 : 0] w,
    input                             e,
    input                             c
  );
    data_in = d;
    weight  = w;
    en      = e;
    clear   = c;

    @(posedge clk); #1;

  endtask

  // Basic accumulation
  task test_basic_accumulation;
    $display("Basic accumulation");

    apply(0, 0, 0, 1);   // clear first
    apply(2, 3, 1, 0);   // acc = 0 + 6  = 6
    apply(4, 5, 1, 0);   // acc = 6 + 20 = 26
    apply(6, 7, 1, 0);   // acc = 26+ 42 = 68

    if (acc_out == 68)
      $display("  PASS  acc_out=%0d", acc_out);
    else
      $display("  FAIL  acc_out=%0d  expected=68", acc_out);

  endtask

  // Clear mid-sequence
  // Accumulate 2 cycles, clear, accumulate 1 more after clear: acc should restart from 0
  task test_clear;
    $display("Clear mid-sequence ");

    apply(0, 0, 0, 1);   // clear
    apply(3, 3, 1, 0);   // acc = 9
    apply(4, 4, 1, 0);   // acc = 9 + 16 = 25
    apply(0, 0, 0, 1);   // clear → acc = 0
    apply(5, 5, 1, 0);   // acc = 25

    if (acc_out == 25)
      $display("  PASS  acc_out=%0d", acc_out);
    else
      $display("  FAIL  acc_out=%0d  expected=25", acc_out);
  endtask

  // Negative weights
  task test_negative_weights;
    $display("Negative weights");

    apply(0,  0, 0, 1);
    apply(3,  4, 1, 0);   // acc = 12
    apply(2, -1, 1, 0);   // acc = 12 - 2 = 10

    if (acc_out == 10)
      $display("  PASS  acc_out=%0d", acc_out);
    else
      $display("  FAIL  acc_out=%0d  expected=10", acc_out);
  
  endtask

  // Accumulator should hold, not accumulate
  task test_en_hold;
    $display("Test 4: en=0 hold");

    apply(0, 0, 0, 1);    // clear
    apply(5, 5, 1, 0);    // acc = 25
    apply(9, 9, 0, 0);    // en=0 : acc should stay 25
    apply(9, 9, 0, 0);    // en=0 : acc should stay 25

    if (acc_out == 25)
      $display("  PASS  acc_out=%0d", acc_out);
    else
      $display("  FAIL  acc_out=%0d  expected=25", acc_out);
  
  endtask

  // TCN conv simulation
  // kernel=3, inputs=[10,20,30], weights=[1,2,3]
  // dot product = 10*1 + 20*2 + 30*3 = 10+40+90 = 140
  task test_tcn_conv;
    $display("Test 5: TCN dot product simulation");
    $display("  inputs=[10,20,30]  weights=[1,2,3]  expected=140");

    apply( 0,  0, 0, 1);
    apply(10,  1, 1, 0);  // acc = 10
    apply(20,  2, 1, 0);  // acc = 10+40  = 50
    apply(30,  3, 1, 0);  // acc = 50+90  = 140

    if (acc_out == 140)
      $display("  PASS  acc_out=%0d", acc_out);
    else
      $display("  FAIL  acc_out=%0d  expected=140", acc_out);
  
  endtask

  initial begin
    $display("MAC Unit Testbench");

    rst_n   = 0;

    en      = 0;
    clear   = 0;

    data_in = 0;
    weight  = 0;
    
    @(posedge clk); #1;
    rst_n   = 1;

    test_basic_accumulation;
    test_clear;
    test_negative_weights;
    test_en_hold;
    test_tcn_conv;

    $display("Done");
    $finish;
  
  end

endmodule
