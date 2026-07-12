module conv1d_1x1 #(
  parameter DATA_WIDTH  = 16,
  parameter ACC_WIDTH   = 32,
  parameter WEIGHT_FILE = "weights_1x1.hex"
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire signed [DATA_WIDTH -1 : 0]  data_in,

  output reg  signed [DATA_WIDTH - 1 : 0] data_out,
  output reg                              valid_out
);

  // Control — 4 cycle pipeline
  //
  // cnt=0 (en=1): latch data_in, mac_clear=1
  // cnt=1:        MAC clears acc; mac_en=1 sent (weight_rd always valid)
  // cnt=2:        MAC accumulates data*weight; wait for register
  // cnt=3:        acc settled, output valid
  localparam CNT_MAX = 3;
  localparam CNT_W   = $clog2(CNT_MAX + 1) + 1;

  // Weight BRAM : single weight (1×1 kernel, 1 in/out channel)
  reg  signed [DATA_WIDTH - 1 : 0] weight_mem [0 : 0];
  reg  signed [DATA_WIDTH - 1 : 0] weight_rd;

  reg         [CNT_W - 1 : 0]      cnt;
  reg  signed [DATA_WIDTH - 1 : 0] data_latch;

  // MAC : single multiply (no accumulation over taps)
  reg                              mac_en;
  reg                              mac_clear;
  reg  signed [DATA_WIDTH - 1 : 0] mac_data;
  wire signed [ACC_WIDTH - 1 : 0]  acc_out;

  wire signed [DATA_WIDTH - 1 : 0] relu_out;

  initial $readmemh(WEIGHT_FILE, weight_mem);

  always_ff @(posedge clk) begin
    weight_rd <= weight_mem[0];
  end

  mac_unit #(
    .DATA_WIDTH (DATA_WIDTH),
    .ACC_WIDTH  (ACC_WIDTH)
  ) mac_unit_01 (
    .clk        (clk),
    .rst_n      (rst_n),

    .en         (mac_en),
    .clear      (mac_clear),
    
    .data_in    (mac_data),
    .weight     (weight_rd),

    .acc_out    (acc_out),
    .valid      ()
  );

  // ReLU
  relu #(
    .DATA_WIDTH (DATA_WIDTH)
  ) relu_01 (
    .data_in    (acc_out [DATA_WIDTH - 1 : 0]),
    .data_out   (relu_out)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt            <= 0;

      mac_en         <= 0;
      mac_clear      <= 0;
      mac_data       <= 0;
      data_latch     <= 0;

      valid_out      <= 0;
      data_out       <= 0;

    end else begin
      mac_en         <= 0;
      mac_clear      <= 0;
      valid_out      <= 0;

      if (cnt == 0) begin
        if (en) begin
          data_latch <= data_in;
          mac_clear  <= 1;         // cycle 0: zero the accumulator
          cnt        <= 1;
        end

      end else if (cnt == 1) begin
        // MAC sees clear=1 this cycle → acc=0
        // Send multiply: weight_rd=w[0] is always valid (BRAM addr fixed at 0)
        mac_en       <= 1;
        mac_data     <= data_latch;
        cnt          <= 2;

      end else if (cnt == 2) begin
        // MAC sees en=1 → acc = 0 + data*weight
        // wait one cycle for acc to settle in register
        cnt          <= 3;

      end else begin
        // cnt == 3: acc settled, output
        data_out     <= relu_out;
        valid_out    <= 1;
        cnt          <= 0;
      end
    end
  end

endmodule