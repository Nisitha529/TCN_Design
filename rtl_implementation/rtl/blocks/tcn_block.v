module tcn_block #(
  parameter KERNEL_SIZE   = 3,

  parameter DILATION_1    = 1,
  parameter DILATION_2    = 2,

  parameter DATA_WIDTH    = 16,
  parameter ACC_WIDTH     = 32,
  
  parameter WEIGHT_FILE_1 = "w1.hex",
  parameter WEIGHT_FILE_2 = "w2.hex"
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire signed [DATA_WIDTH - 1 : 0] data_in,

  output reg  signed [DATA_WIDTH - 1 : 0] data_out,
  output reg                              valid_out
);

  // Each causal_conv1d: KERNEL_SIZE+3 cycles from en = 1 to valid_out = 1
  localparam CONV_LAT    = KERNEL_SIZE + 3;
  localparam MAIN_LAT    = 2 * CONV_LAT;   // K = 3 : 12 cycles

  wire signed [DATA_WIDTH - 1 : 0] conv1_out;
  wire                             conv1_valid;

  wire signed [DATA_WIDTH - 1 : 0] conv2_out;
  wire                             conv2_valid;

  wire signed [DATA_WIDTH - 1 : 0] sum;

  wire signed [DATA_WIDTH - 1 : 0] relu_out;

  reg  signed [DATA_WIDTH - 1 : 0] res_delay    [0:MAIN_LAT-1];
  
  integer                          j;

  // Conv1 : dilation 1
  causal_conv1d #(
    .KERNEL_SIZE (KERNEL_SIZE),
    .DILATION    (DILATION_1),
    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),
    .WEIGHT_FILE (WEIGHT_FILE_1)
  ) causal_conv1d_01 (
    .clk         (clk),
    .rst_n       (rst_n),

    .en          (en),
    .data_in     (data_in),

    .data_out    (conv1_out),
    .valid_out   (conv1_valid)
  );

  // Conv2 : dilation 2, triggered by conv1's valid output
  causal_conv1d #(
    .KERNEL_SIZE (KERNEL_SIZE),
    .DILATION    (DILATION_2),
    .DATA_WIDTH  (DATA_WIDTH),
    .ACC_WIDTH   (ACC_WIDTH),
    .WEIGHT_FILE (WEIGHT_FILE_2)
  ) causal_conv1d_02 (
    .clk         (clk),
    .rst_n       (rst_n),

    .en          (conv1_valid),    // Chained: conv1 output feeds conv2 enable
    .data_in     (conv1_out),

    .data_out    (conv2_out),
    .valid_out   (conv2_valid)
  );

  // Residual add : Saturating to prevent overflow wrap
  adder_sat #(
    .DATA_WIDTH  (DATA_WIDTH)
  ) adder_sat_01 (
    .a           (conv2_out),
    .b           (res_delay[MAIN_LAT - 1]),

    .result      (sum)
  );

  // Final ReLU (matches Python: self.relu(out + res))
  relu #(
    .DATA_WIDTH  (DATA_WIDTH)
  ) relu_01 (
    .data_in     (sum),

    .data_out    (relu_out)
  );

  // Residual delay
  // Shifts every cycle, read at MAIN_LAT-1 data_in captured at T, arrives at tap[MAIN_LAT-1] at T+MAIN_LAT
  // which aligns exactly with conv2_valid = 1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (j = 0; j < MAIN_LAT; j = j + 1) begin
        res_delay [j] <= 0;
      end

    end else begin
      res_delay [0]   <= data_in;

      for (j = 1; j < MAIN_LAT; j = j + 1) begin
        res_delay [j] <= res_delay [j - 1];
      end

    end
  end

  // Output register : 1 cycle after conv2_valid
  // Total latency from en = 1: MAIN_LAT + 1 = 13 cycles (K = 3)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      data_out        <= 0;
      valid_out       <= 0;

    end else begin
      valid_out       <= conv2_valid;

      if (conv2_valid) begin
        data_out      <= relu_out;
      end

    end
  end

endmodule