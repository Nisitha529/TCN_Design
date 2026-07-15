`timescale 1ns/1ps

module tb_causal_conv1d;

  parameter KERNEL_SIZE = 3;
  parameter DILATION    = 1;

  parameter DATA_WIDTH  = 16;
  parameter ACC_WIDTH   = 32;
  
  parameter CLK_PERIOD  = 10;

  logic                             clk;
  logic                             rst_n;

  logic                             en;
  logic signed [DATA_WIDTH - 1 : 0] data_in;

  wire  signed [DATA_WIDTH - 1 : 0] data_out;
  wire                              valid_out;

  causal_conv1d #(
    .KERNEL_SIZE (KERNEL_SIZE),
    .DILATION    (DILATION),

    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),

    .WEIGHT_FILE ("../../weights/test_conv_weights.hex"),
    .BIAS_FILE   ("../../weights/test_conv_bias.hex")
  ) dut_causal_conv1d (
    .clk         (clk),
    .rst_n       (rst_n),

    .en          (en),
    .data_in     (data_in),

    .data_out    (data_out),
    .valid_out   (valid_out)
  );

  initial clk = 0;

  always #(CLK_PERIOD/2) clk = ~clk;

  // Apply one input, wait for valid output
  task apply_input(input signed [DATA_WIDTH - 1 : 0] val, input signed [DATA_WIDTH - 1 : 0] expected);
    // Present input
    data_in = val;
    en      = 1;

    @(posedge clk); #1;
    en      = 0;

    // Wait for valid_out pulse (max KERNEL_SIZE+4 cycles)
    repeat (KERNEL_SIZE + 4) begin
      @(posedge clk); #1;
      if (valid_out) begin
        if (data_out === expected) begin
          $display("PASS  input = %-3d  output = %-4d  expected = %-4d", val, data_out, expected);
        end else begin
          $display("FAIL  input = %-3d  output = %-4d  expected = %-4d", val, data_out, expected);
        end

        disable apply_input;
      end
    end
    $display("TIMEOUT waiting for valid_out (input = %0d)", val);
  endtask

  // Test: weights = [1, 2, 3], inputs = [1, 2, 3, 4, 5]
  //
  // Convolution output at time t (dilation=1):
  //   out[t] = x [t] * 1 + x [t - 1] * 2 + x [t - 2] * 3
  //
  // out[0] = 1 : 1 * 1 + 0 * 2 + 0 * 3 = 1
  // out[1] = 2 : 2 * 1 + 1 * 2 + 0 * 3 = 4
  // out[2] = 3 : 3 * 1 + 2 * 2 + 1 * 3 = 10
  // out[3] = 4 : 4 * 1 + 3 * 2 + 2 * 3 = 16
  // out[4] = 5 : 5 * 1 + 4 * 2 + 3 * 3 = 22
  initial begin
    $display("CausalConv1d Testbench");
    $display("weights = [1, 2, 3]  dilation = %0d  kernel = %0d", DILATION, KERNEL_SIZE);

    rst_n   = 0;
    en      = 0;
    data_in = 0;

    repeat(2) @(posedge clk); #1;
    rst_n   = 1;

    apply_input(16'sd1,  16'sd1);
    apply_input(16'sd2,  16'sd4);
    apply_input(16'sd3,  16'sd10);
    apply_input(16'sd4,  16'sd16);
    apply_input(16'sd5,  16'sd22);

    $display("Done");
    $finish;
    
  end

endmodule
