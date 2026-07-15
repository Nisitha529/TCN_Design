`timescale 1ns/1ps

// Multi-channel causal_conv1d testbench
// IN_CHANNELS=1, OUT_CHANNELS=2, KERNEL_SIZE=3, DILATION=1
//
// Weights (out_ch major, IN_CH*K taps per out_ch):
//   out_ch=0: [1, 2, 3]
//   out_ch=1: [3, 2, 1]
// Bias: [0, 0]
//
// Ports use flat packed vectors: channel ch at bits [ch*DW +: DW]
//
// Expected outputs for inputs [1..5]:
//   t=0: out[0]= 1   out[1]= 3
//   t=1: out[0]= 4   out[1]= 8
//   t=2: out[0]=10   out[1]=14
//   t=3: out[0]=16   out[1]=20
//   t=4: out[0]=22   out[1]=26

module tb_causal_conv1d_mc;

  localparam IN_CHANNELS   = 1;
  localparam OUT_CHANNELS  = 2;

  localparam KERNEL_SIZE   = 3;
  localparam DILATION      = 1;

  localparam DATA_WIDTH    = 16;
  localparam ACC_WIDTH     = 32;

  localparam CLK_PERIOD    = 10;

  // total latency = OUT_CHANNELS * (IN_CH*K + 2) cycles after en pulse
  localparam STEPS_PER_OUT = IN_CHANNELS * KERNEL_SIZE;
  localparam LATENCY       = OUT_CHANNELS * (STEPS_PER_OUT + 2);
  localparam TIMEOUT       = LATENCY + 4;

  logic                                            clk;
  logic                                            rst_n;

  logic                                            en;

  // flat input: 1 channel : same width as DATA_WIDTH
  logic signed [IN_CHANNELS * DATA_WIDTH - 1 : 0]  data_in;

  // flat output: 2 channels packed
  wire         [OUT_CHANNELS * DATA_WIDTH - 1 : 0] data_out;
  wire                                             valid_out;

  // per-channel output aliases for easy display
  wire signed  [DATA_WIDTH - 1 : 0] out_ch0 = $signed(data_out[0*DATA_WIDTH +: DATA_WIDTH]);
  wire signed  [DATA_WIDTH - 1 : 0] out_ch1 = $signed(data_out[1*DATA_WIDTH +: DATA_WIDTH]);

  causal_conv1d #(
    .IN_CHANNELS  (IN_CHANNELS),
    .OUT_CHANNELS (OUT_CHANNELS),

    .KERNEL_SIZE  (KERNEL_SIZE),
    .DILATION     (DILATION),

    .DATA_WIDTH   (DATA_WIDTH),
    .ACC_WIDTH    (ACC_WIDTH),

    .WEIGHT_FILE  ("../../weights/test_mc_weights.hex"),
    .BIAS_FILE    ("../../weights/test_mc_bias.hex")
  ) dut_causal_conv1d (
    .clk          (clk),
    .rst_n        (rst_n),

    .en           (en),
    .data_in      (data_in),

    .data_out     (data_out),
    .valid_out    (valid_out)
  );

  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  integer pass_cnt;
  integer fail_cnt;

  task apply_input(
    input signed [DATA_WIDTH - 1 : 0] val,
    input signed [DATA_WIDTH - 1 : 0] exp0,
    input signed [DATA_WIDTH - 1 : 0] exp1
  );
    integer t;

    data_in = val;
    en      = 1;

    @(posedge clk); #1;
    en      = 0;

    for (t = 0; t < TIMEOUT; t = t + 1) begin
      @(posedge clk); #1;
      if (valid_out) begin
        if (out_ch0 === exp0 && out_ch1 === exp1) begin
          $display("PASS  in = %-3d  out [0] = %-3d (exp %-3d)  out [1] = %-3d (exp %-3d)", val, out_ch0, exp0, out_ch1, exp1);
          pass_cnt = pass_cnt + 1;

        end else begin
          $display("FAIL  in = %-3d  out [0] = %-3d (exp %-3d)  out [1] =%-3d (exp %-3d)", val, out_ch0, exp0, out_ch1, exp1);
          fail_cnt = fail_cnt + 1;

        end
        disable apply_input;

      end
    end
    $display("TIMEOUT  in = %0d  (no valid_out after %0d cycles)", val, TIMEOUT);
    fail_cnt = fail_cnt + 1;

  endtask

  initial begin
    $display("causal_conv1d multi-channel testbench");
    $display("IN = %0d  OUT = %0d  K = %0d  DIL = %0d  latency = %0d cycles", IN_CHANNELS, OUT_CHANNELS, KERNEL_SIZE, DILATION, LATENCY);

    pass_cnt = 0;
    fail_cnt = 0;
    rst_n    = 0;
    en       = 0;
    data_in  = 0;

    repeat(2) @(posedge clk); #1;
    rst_n = 1;

    apply_input(16'sd1,  16'sd1,   16'sd3);
    apply_input(16'sd2,  16'sd4,   16'sd8);
    apply_input(16'sd3,  16'sd10,  16'sd14);
    apply_input(16'sd4,  16'sd16,  16'sd20);
    apply_input(16'sd5,  16'sd22,  16'sd26);

    $display("Results: %0d PASS  %0d FAIL", pass_cnt, fail_cnt);
    $finish;

  end

endmodule
