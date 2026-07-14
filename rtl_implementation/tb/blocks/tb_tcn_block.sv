`timescale 1ns/1ps

module tb_tcn_block ();

  parameter KERNEL_SIZE = 3;

  parameter DIALATION_1 = 1;
  parameter DIALATION_2 = 2;

  parameter DATA_WIDTH  = 16;
  parameter ACC_WIDTH   = 32;

  parameter CLK_PERIOD  = 10;

  // latency = 2 * (KERNEL_SIZE + 3) + 1 = 13 cycles
  localparam TOTAL_LAT = 2 * (KERNEL_SIZE + 3) + 1;

  logic                             clk;
  logic                             rst_n;

  logic                             en;
  logic signed [DATA_WIDTH - 1 : 0] data_in;

  wire  signed [DATA_WIDTH - 1 : 0] data_out;
  wire                              valid_out;

  tcn_block #(
    .KERNEL_SIZE   (KERNEL_SIZE),

    .DILATION_1    (DIALATION_1),
    .DILATION_2    (DIALATION_2),

    .DATA_WIDTH    (DATA_WIDTH),
    .ACC_WIDTH     (ACC_WIDTH),

    .WEIGHT_FILE_1 ("../../weights/tcn_block_w1.hex"),
    .WEIGHT_FILE_2 ("../../weights/tcn_block_w2.hex")
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),

    .en            (en),
    .data_in       (data_in),

    .data_out      (data_out),
    .valid_out     (valid_out)
  );

  initial clk = 0;

  always #(CLK_PERIOD/2) begin
    clk       = ~clk;
  end

  task apply_input(input signed [DATA_WIDTH - 1 : 0] val, input signed [DATA_WIDTH - 1 : 0] expected);
    data_in   = val;
    en        = 1;

    @(posedge clk); #1;
    en        = 0;
    data_in   = 0;

    repeat (TOTAL_LAT + 4) begin
      @(posedge clk); #1;

      if (valid_out) begin
        if (data_out === expected) begin
          $display("PASS  input = %-4d  output = %-4d  expected = %-4d", val, data_out, expected);
        end else begin
          $display("FAIL  input = %-4d  output = %-4d  expected = %-4d", val, data_out, expected);
        end

        disable apply_input;

      end
    end

    $display("Timeout (input = %0d)", val);

  endtask

  // weights = [1, 0, 0] both convs : output = relu(relu(x) + x) = 2x for x>0
  initial begin
    $display("TCN Block Testbench");
    $display("w1 = w2 = [1, 0, 0]  d1 = %0d d2 = %0d  K = %0d  expected_lat = %0d", 1, 2, KERNEL_SIZE, TOTAL_LAT);

    rst_n   = 0; 
    en      = 0; 
    data_in = 0;

    repeat(2) @(posedge clk); #1;
    rst_n   = 1;

    apply_input(16'sd3,  16'sd6);    // relu(relu(3)+3) = 6
    apply_input(16'sd5,  16'sd10);   // 10
    apply_input(16'sd10, 16'sd20);   // 20
    apply_input(16'sd0,  16'sd0);    // 0

    $display("Done");
    $finish;
  end

endmodule
