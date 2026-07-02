`timescale 1ns/1ps

module tb_relu ();

  parameter DATA_WIDTH = 16;

  logic signed [DATA_WIDTH - 1 : 0] data_in;
  logic signed [DATA_WIDTH - 1 : 0] data_out;

  relu # (
    .DATA_WIDTH (DATA_WIDTH)
  ) dut (
    .data_in    (data_in),
    .data_out   (data_out)
  );

  task check_relu (input signed [DATA_WIDTH - 1 : 0] in, input signed [DATA_WIDTH - 1 : 0] expected);
    begin
      data_in = in;
      #1;

      if (data_out !== expected) begin
        $display("Test failed for input %0d: expected %0d, got %0d", in, expected, data_out);
      end else begin
        $display("Test passed for input %0d: got %0d", in, data_out);
      end

    end

  endtask

  initial begin
    $display  ("--- ReLU Testbench ---");

    check_relu(  16'sd100,   16'sd100);   // positive → pass through
    check_relu(  16'sd0,     16'sd0);     // zero     → zero
    check_relu(-16'sd1,      16'sd0);     // negative → zero
    check_relu(-16'sd32768,  16'sd0);     // most negative INT16 → zero
    check_relu(  16'sd32767, 16'sd32767); // max positive → pass through
    check_relu(-16'sd500,    16'sd0);     // negative → zero

    $display  ("--- Done ---");
    $finish;

  end

endmodule