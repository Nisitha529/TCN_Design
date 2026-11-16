`timescale 1ns/1ps

// tb_requant -- rtl/primitives/requant.sv against the golden model's arithmetic.
//
// Vectors from gen_requant_vectors.py (numpy >>, clip, max -- the operations
// of qos_tcn/quant.py). Two instances, RELU=1 and RELU=0, are fed one vector
// per cycle (full throughput) and every output is compared, in order, 2 cycles
// after its input. Covers the corners (most negative/positive sums, floor of
// negative values, both saturation edges) and random sums.
//
//   iverilog -g2012 -Ptb_requant.NV=<count> -Ptb_requant.VFILE=\"<dir>/rq.hex\" ...

module tb_requant;

  parameter NV    = 1000;
  parameter VFILE = "rq.hex";

  logic clk = 0, rst = 1, v = 0;
  logic signed [31:0] acc;
  logic signed [15:0] bias;
  wire  signed [15:0] y_r, y_l;
  wire  vo_r, vo_l;
  always #2 clk = ~clk;

  requant #(.RELU(1)) dut_relu (.clk(clk), .rst(rst), .valid_in(v), .acc(acc), .bias(bias), .valid_out(vo_r), .y(y_r));
  requant #(.RELU(0)) dut_lin  (.clk(clk), .rst(rst), .valid_in(v), .acc(acc), .bias(bias), .valid_out(vo_l), .y(y_l));

  // one line = acc[79:48] bias[47:32] y_relu[31:16] y_lin[15:0]
  logic [79:0] vec [0 : NV - 1];
  initial $readmemh(VFILE, vec);

  int got = 0, bad_r = 0, bad_l = 0;
  always @(posedge clk) begin
    if (vo_r) begin
      logic [15:0] er, el;
      er = vec[got][31:16]; el = vec[got][15:0];
      if (y_r !== er) begin if (bad_r < 5) $display("    RELU mismatch #%0d acc=%0d bias=%0d: got %0d want %0d",
                              got, $signed(vec[got][79:48]), $signed(vec[got][47:32]), y_r, $signed(er)); bad_r++; end
      if (y_l !== el) begin if (bad_l < 5) $display("    LIN  mismatch #%0d: got %0d want %0d", got, y_l, $signed(el)); bad_l++; end
      if (vo_l !== 1'b1) bad_l++;
      got++;
    end
  end

  initial begin
    repeat (3) @(posedge clk); @(negedge clk); rst = 0;
    for (int i = 0; i < NV; i++) begin
      @(negedge clk);
      acc = vec[i][79:48]; bias = vec[i][47:32];
      v = 1;
    end
    @(negedge clk); v = 0;
    repeat (5) @(posedge clk);
    $display("requant: %0d vectors, %0d outputs checked; RELU=1 mismatches %0d, RELU=0 mismatches %0d",
             NV, got, bad_r, bad_l);
    $display("  Results: %0d passed, %0d failed", (got == NV && bad_r == 0 && bad_l == 0) ? 1 : 0,
             (got == NV && bad_r == 0 && bad_l == 0) ? 0 : 1);
    $finish;
  end

endmodule
