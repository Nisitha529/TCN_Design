`timescale 1ns/1ps

module tb_adder_sat ();

  parameter DATA_WIDTH = 16;

  logic signed [DATA_WIDTH - 1 : 0] a; 
  logic signed [DATA_WIDTH - 1 : 0] b;

  wire  signed [DATA_WIDTH - 1 : 0] result;

  adder_sat #(
    .DATA_WIDTH (DATA_WIDTH)
  ) dut_adder_sat (
    .a          (a),
    .b          (b),

    .result     (result)
  );

  task check(
    input signed [DATA_WIDTH - 1 : 0] in_a,
    input signed [DATA_WIDTH - 1 : 0] in_b,

    input signed [DATA_WIDTH - 1 : 0] expected
  );
    a = in_a; 
    b = in_b; 
    #1;

    if (result === expected)
      $display("PASS  %0d + %0d = %0d", in_a, in_b, result);
    else
      $display("FAIL  %0d + %0d = %0d  expected=%0d", in_a, in_b, result, expected);

  endtask

  localparam signed [DATA_WIDTH - 1 : 0] MAX =  {1'b0, {(DATA_WIDTH-1){1'b1}}};  
  localparam signed [DATA_WIDTH - 1 : 0] MIN =  {1'b1, {(DATA_WIDTH-1){1'b0}}};  

  initial begin
    $display("Saturating Adder Testbench");

    // Normal addition : no overflow
    check(100,  200,   300);
    check(-100, -200,  -300);
    check(100,  -200,  -100);

    // Positive overflow : clamp to MAX
    check(MAX,   1,     MAX);
    check(MAX,   MAX,   MAX);
    check(20000, 20000, MAX);

    // Negative overflow : clamp to MIN
    check(MIN,    -1,     MIN);
    check(MIN,    MIN,    MIN);
    check(-20000, -20000, MIN);

    // Boundary : no overflow
    check( MAX,     0,  MAX);
    check( MIN,     0,  MIN);

    $display("Done");
    $finish;
  end

endmodule
