`timescale 1ns/1ps

// win_block -- one TCN residual block over a whole window.
//
//   y1  = relu(conv1(x))            win_conv CI -> CO, K, D
//   y2  = relu(conv2(y1))           win_conv CO -> CO, K, D
//   r   = res(x)  or  x             1x1 win_conv (no ReLU) when CI != CO
//   out = relu(sat16(y2 + r))
// Bit-exact with the block loop in IntModel.int_forward (qos_tcn/quant.py).
// conv1 and the residual conv run in parallel; conv2 waits for conv1.

module win_block #(
  parameter CI = 15,
  parameter CO = 32,
  parameter K  = 3,
  parameter D  = 1,
  parameter N  = 8,
  parameter P  = 8,
  parameter DW = 16,
  parameter W1_FILE = "c1_w.hex", parameter B1_FILE = "c1_b.hex",
  parameter W2_FILE = "c2_w.hex", parameter B2_FILE = "c2_b.hex",
  parameter RW_FILE = "res_w.hex", parameter RB_FILE = "res_b.hex"
)(
  input  wire                       clk,
  input  wire                       rst_n,
  input  wire                       start,
  input  wire [N * CI * DW - 1 : 0] x,
  output reg  [N * CO * DW - 1 : 0] y,
  output reg                        done
);

  localparam HAS_RES = (CI != CO);

  wire [N * CO * DW - 1 : 0] y1, y2, r;
  wire done1, done2, done_r;
  reg  start2, got1, got_r, wait2;

  win_conv #(.CI(CI), .CO(CO), .K(K), .D(D), .N(N), .P(P), .RELU(1), .DW(DW),
             .W_FILE(W1_FILE), .B_FILE(B1_FILE))
    c1 (.clk(clk), .rst_n(rst_n), .start(start), .x(x), .y(y1), .done(done1), .busy());

  win_conv #(.CI(CO), .CO(CO), .K(K), .D(D), .N(N), .P(P), .RELU(1), .DW(DW),
             .W_FILE(W2_FILE), .B_FILE(B2_FILE))
    c2 (.clk(clk), .rst_n(rst_n), .start(start2), .x(y1), .y(y2), .done(done2), .busy());

  generate
    if (HAS_RES) begin : g_res
      win_conv #(.CI(CI), .CO(CO), .K(1), .D(1), .N(N), .P(P), .RELU(0), .DW(DW),
                 .W_FILE(RW_FILE), .B_FILE(RB_FILE))
        rc (.clk(clk), .rst_n(rst_n), .start(start), .x(x), .y(r), .done(done_r), .busy());
    end else begin : g_id
      assign r = x;
      assign done_r = done1;          // identity residual is ready when conv1 is
    end
  endgenerate

  // out = relu(sat16(y2 + r)), all positions and channels at once
  wire [N * CO * DW - 1 : 0] sum;
  genvar g;
  generate
    for (g = 0; g < N * CO; g = g + 1) begin : add
      wire signed [DW : 0] s = $signed(y2[g * DW +: DW]) + $signed(r[g * DW +: DW]);
      wire signed [DW - 1 : 0] sat = (s >  $signed({2'b00, {(DW - 1){1'b1}}})) ? {1'b0, {(DW - 1){1'b1}}} :
                                     (s < -$signed({2'b01, {(DW - 1){1'b0}}})) ? {1'b1, {(DW - 1){1'b0}}} :
                                     s[DW - 1 : 0];
      assign sum[g * DW +: DW] = sat[DW - 1] ? '0 : sat;
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start2 <= 1'b0; got1 <= 1'b0; got_r <= 1'b0; wait2 <= 1'b0; done <= 1'b0;
    end else begin
      start2 <= 1'b0;
      done   <= 1'b0;
      if (start) begin got1 <= 1'b0; got_r <= 1'b0; end
      if (done1)  got1  <= 1'b1;
      if (done_r) got_r <= 1'b1;
      if ((got1 || done1) && (got_r || done_r) && !wait2 && !start2) begin
        start2 <= 1'b1; wait2 <= 1'b1; got1 <= 1'b0; got_r <= 1'b0;
      end
      if (done2) begin
        y <= sum; done <= 1'b1; wait2 <= 1'b0;
      end
    end
  end

endmodule
