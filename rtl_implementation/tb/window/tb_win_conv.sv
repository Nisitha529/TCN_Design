`timescale 1ns/1ps

// tb_win_conv -- win_conv against the golden model's convolution
// (vectors from gen_conv_vectors.py, which calls qos_tcn/quant.py).
// Checks every output value of every window, bit for bit, and the cycle count
// against N * (CO/P) * CI * K.

module tb_win_conv;

  parameter CI = 4, CO = 8, K = 3, D = 1, N = 8, P = 4, RELU = 1, NV = 50;
  parameter VDIR = ".";
  localparam DW = 16;

  logic clk = 0, rst_n = 0, start = 0;
  always #2 clk = ~clk;

  logic [N * CI * DW - 1 : 0] x;
  wire  [N * CO * DW - 1 : 0] y;
  wire done, busy;

  win_conv #(.CI(CI), .CO(CO), .K(K), .D(D), .N(N), .P(P), .RELU(RELU),
             .W_FILE({VDIR, "/w.hex"}), .B_FILE({VDIR, "/b.hex"})) dut (
    .clk(clk), .rst_n(rst_n), .start(start), .x(x), .y(y), .done(done), .busy(busy));

  logic [N * CI * DW - 1 : 0] xv [0 : NV - 1];
  logic [N * CO * DW - 1 : 0] yv [0 : NV - 1];
  initial begin
    $readmemh({VDIR, "/x.hex"}, xv);
    $readmemh({VDIR, "/y.hex"}, yv);
  end

  int bad_vec = 0, bad_val = 0, cycles = 0;
  initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    for (int v = 0; v < NV; v++) begin
      @(negedge clk); x = xv[v]; start = 1;
      @(negedge clk); start = 0;
      cycles = 1;
      while (!done) begin @(posedge clk); cycles++; end
      @(negedge clk);
      if (y !== yv[v]) begin
        bad_vec++;
        for (int j = 0; j < N * CO; j++)
          if (y[j * DW +: DW] !== yv[v][j * DW +: DW]) begin
            if (bad_val < 5)
              $display("    mismatch vec %0d t=%0d o=%0d: got %0d want %0d", v, j / CO, j % CO,
                       $signed(y[j * DW +: DW]), $signed(yv[v][j * DW +: DW]));
            bad_val++;
          end
      end
    end
    $display("win_conv CI=%0d CO=%0d K=%0d D=%0d N=%0d P=%0d RELU=%0d: %0d/%0d windows exact, %0d cycles/window (ideal %0d)",
             CI, CO, K, D, N, P, RELU, NV - bad_vec, NV, cycles, N * (CO / P) * CI * K);
    $display("  Results: %0d passed, %0d failed", (bad_vec == 0) ? 1 : 0, (bad_vec == 0) ? 0 : 1);
    $finish;
  end

  initial begin #20000000; $display("[TIMEOUT]"); $finish; end

endmodule
