`timescale 1ns/1ps

// tcn_block testbench : single channel (IN = 1, OUT = 1, HAS_RES_CONV = 0)
//
// Both convolutions: weights = [1, 0, 0], bias = 0, dilation = 1
// Identity residual: data_in is delayed by MAIN_LAT and added to conv2 output
//
// Per-sample expected output: relu(relu(x) + x) = relu(x+x) = 2x for x>0
//
// New latency formula: CONV1_LAT = OUT * (IN * K + 2) = 1 * (1 * 3 + 2) = 5
//                      CONV2_LAT = OUT * (OUT * K + 2) = 1 * (1 * 3 + 2) = 5
//                      MAIN_LAT  = 10, TOTAL_LAT = MAIN_LAT + 1 = 11

module tb_tcn_block ();

  localparam IN_CHANNELS  = 1;
  localparam OUT_CHANNELS = 1;

  localparam KERNEL_SIZE  = 3;
  localparam DILATION     = 1;

  localparam DATA_WIDTH   = 16;
  localparam ACC_WIDTH    = 32;

  localparam CONV1_LAT    = OUT_CHANNELS * (IN_CHANNELS  * KERNEL_SIZE + 2);
  localparam CONV2_LAT    = OUT_CHANNELS * (OUT_CHANNELS * KERNEL_SIZE + 2);
  localparam MAIN_LAT     = CONV1_LAT + 1 + CONV2_LAT;                       // +1 for chaining register
  localparam TOTAL_LAT    = MAIN_LAT  + 1;                                   // +1 for output register

  localparam CLK_PERIOD   = 10;

  logic                                     clk;
  logic                                     rst_n;

  logic                                     en;
  logic [IN_CHANNELS  * DATA_WIDTH - 1 : 0] data_in;

  wire  [OUT_CHANNELS * DATA_WIDTH - 1 : 0] data_out;
  wire                                      valid_out;

  // scalar aliases (IN=OUT=1, so same width as DATA_WIDTH)
  wire signed [DATA_WIDTH - 1 : 0] out_ch0 = $signed(data_out [DATA_WIDTH - 1 : 0]);

  tcn_block #(
    .IN_CHANNELS   (IN_CHANNELS),
    .OUT_CHANNELS  (OUT_CHANNELS),

    .KERNEL_SIZE   (KERNEL_SIZE),
    .DILATION      (DILATION),

    .DATA_WIDTH    (DATA_WIDTH),
    .ACC_WIDTH     (ACC_WIDTH),

    .HAS_RES_CONV  (0),

    .WEIGHT_FILE_1 ("../../weights/tcn_block_w1.hex"),
    .BIAS_FILE_1   ("../../weights/tcn_block_b1.hex"),
    .WEIGHT_FILE_2 ("../../weights/tcn_block_w2.hex"),
    .BIAS_FILE_2   ("../../weights/tcn_block_b2.hex")
  ) dut_tcn_block (
    .clk      (clk),
    .rst_n    (rst_n),

    .en       (en),
    .data_in  (data_in),

    .data_out (data_out),
    .valid_out(valid_out)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  task apply_input(
    input signed [DATA_WIDTH - 1 : 0] val,
    input signed [DATA_WIDTH - 1 : 0] expected
  );
    integer t;

    data_in = val;
    en      = 1;

    @(posedge clk); #1;
    en      = 0;
    data_in = 0;

    for (t = 0; t < TOTAL_LAT + 4; t = t + 1) begin
      @(posedge clk); #1;
      if (valid_out) begin
        if (out_ch0 === expected) begin
          $display("PASS  input = %-4d  output = %-4d  expected = %-4d", val, out_ch0, expected);
        end else begin
          $display("FAIL  input = %-4d  output = %-4d  expected = %-4d", val, out_ch0, expected);
        end
        disable apply_input;
      end
    end
    $display("TIMEOUT  input = %0d", val);
  endtask

  // weights = [1, 0, 0] bias = 0: conv output = input (identity filter)
  // out = relu(relu(x)+x) = 2x for x>0, 0 for x<=0
  initial begin
    $display("TCN Block Testbench");
    $display("IN = %0d  OUT = %0d  K = %0d  DIL = %0d", IN_CHANNELS, OUT_CHANNELS, KERNEL_SIZE, DILATION);
    $display("CONV1_LAT = %0d  CONV2_LAT = %0d  MAIN_LAT = %0d  TOTAL = %0d", CONV1_LAT, CONV2_LAT, MAIN_LAT, TOTAL_LAT);

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
