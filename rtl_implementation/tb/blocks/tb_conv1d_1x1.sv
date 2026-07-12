`timescale 1ns/1ps

module tb_conv1d_1x1 ();

  parameter DATA_WIDTH = 16;
  parameter ACC_WIDTH  = 32;
  parameter CLK_PERIOD = 10;

  logic                             clk;
  logic                             rst_n;

  logic                             en;
  logic signed [DATA_WIDTH - 1 : 0] data_in;

  wire  signed [DATA_WIDTH - 1 : 0] data_out;
  wire                              valid_out;

  conv1d_1x1 #(
    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),
    .WEIGHT_FILE ("../../weights/test_1x1_weights.hex")
  ) dut (
    .clk         (clk),
    .rst_n       (rst_n),

    .en          (en),
    .data_in     (data_in),

    .data_out    (data_out),
    .valid_out   (valid_out)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  task apply_input(input signed [DATA_WIDTH - 1 : 0] val, input signed [DATA_WIDTH - 1 : 0] expected);
    data_in = val;
    en      = 1;

    @(posedge clk); #1;
    en = 0;

    repeat (6) begin
      @(posedge clk); #1;

      if (valid_out) begin
        if (data_out === expected) begin
          $display("PASS  input=%-4d  output=%-4d  expected=%-4d", val, data_out, expected);
        end else begin
          $display("FAIL  input=%-4d  output=%-4d  expected=%-4d", val, data_out, expected);
        end

        disable apply_input;

      end

    end

    $display("TIMEOUT (input=%0d)", val);

  endtask

  // weight=2: out = relu(in * 2)
  // Negatives clipped to 0 by relu
  initial begin
    $display("Conv1d_1x1 Testbench (weight=2)");
    rst_n = 0; en = 0; data_in = 0;
    repeat(2) @(posedge clk); #1;
    rst_n = 1;

    apply_input(16'sd3,   16'sd6);
    apply_input(16'sd5,   16'sd10);
    apply_input(-16'sd4,  16'sd0);   // negative → relu clips to 0
    apply_input(16'sd10,  16'sd20);
    apply_input(16'sd0,   16'sd0);

    $display("Done");
    $finish;

  end

endmodule