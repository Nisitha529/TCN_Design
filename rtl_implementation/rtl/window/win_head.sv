`timescale 1ns/1ps

// win_head -- flattened linear output layer and argmax.
//
// Bit-exact with the head in IntModel.int_forward (qos_tcn/quant.py):
//   flat[j], j = c*N + t   (channel-major, as torch's flatten of [C, N])
//   acc[cls] = sum_j w[cls][j] * flat[j]                  ACC_W bits
//   logit    = sat32((acc >>> FRAC) + b[cls])
//   class    = index of the first maximum logit
// One input per cycle, all classes in parallel: C*N cycles + 3.
// Weight memory: word j = {w[NCLS-1][j], ..., w[0][j]} (class 0 at the LSB end).

module win_head #(
  parameter C      = 64,
  parameter N      = 8,
  parameter NCLS   = 5,
  parameter DW     = 16,
  parameter ACC_W  = 32,
  parameter FRAC   = 8,
  parameter W_FILE = "head_w.hex",
  parameter B_FILE = "head_b.hex"
)(
  input  wire                       clk,
  input  wire                       rst_n,
  input  wire                       start,
  input  wire [N * C * DW - 1 : 0]  h,          // position-major, as win_block's y
  output reg  [NCLS * 32 - 1 : 0]   logits,
  output reg  [$clog2(NCLS) - 1 : 0] cls,
  output reg                        done
);

  localparam J  = C * N;
  localparam JW = $clog2(J + 1);
  localparam signed [ACC_W : 0] LMAX =  (64'sd1 <<< 31) - 1;
  localparam signed [ACC_W : 0] LMIN = -(64'sd1 <<< 31);

  reg [NCLS * DW - 1 : 0] wmem [0 : J - 1];
  reg signed [DW - 1 : 0] bmem [0 : NCLS - 1];
  initial begin
    $readmemh(W_FILE, wmem);
    $readmemh(B_FILE, bmem);
  end

  reg                     run, b_v, b_first, b_last, fin;
  reg [JW - 1 : 0]        j;
  reg [NCLS * DW - 1 : 0] b_w;
  reg signed [DW - 1 : 0] b_h;
  reg [NCLS * ACC_W - 1 : 0] acc;
  reg [$clog2(NCLS) - 1 : 0] best;

  // flat index j = c*N + t reads h at position t, channel c
  wire [JW - 1 : 0] jc = j / N;
  wire [JW - 1 : 0] jt = j % N;

  always_ff @(posedge clk) begin
    b_w     <= wmem[j];
    b_h     <= $signed(h[(jt * C + jc) * DW +: DW]);
    b_first <= (j == 0);
    b_last  <= (j == J - 1);
  end

  wire [NCLS * ACC_W - 1 : 0] nacc;
  genvar g;
  generate
    for (g = 0; g < NCLS; g = g + 1) begin : lane
      wire signed [ACC_W - 1 : 0] prod = $signed(b_w[g * DW +: DW]) * b_h;
      assign nacc[g * ACC_W +: ACC_W] = b_first ? prod : $signed(acc[g * ACC_W +: ACC_W]) + prod;
    end
  endgenerate

  function automatic [31 : 0] finish(input [ACC_W - 1 : 0] a, input [DW - 1 : 0] bias);
    reg signed [ACC_W : 0] v;
    v = ($signed(a) >>> FRAC) + $signed(bias);
    if (v > LMAX) v = LMAX;
    if (v < LMIN) v = LMIN;
    finish = v[31 : 0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; b_v <= 1'b0; fin <= 1'b0; done <= 1'b0; j <= '0;
    end else begin
      done <= 1'b0;
      fin  <= 1'b0;
      b_v  <= run;
      if (start && !run && !b_v) begin
        run <= 1'b1; j <= '0;
      end else if (run) begin
        if (j == J - 1) run <= 1'b0;
        else            j <= j + 1'b1;
      end
      if (b_v) begin
        acc <= nacc;
        if (b_last) begin
          for (int c = 0; c < NCLS; c++)
            logits[c * 32 +: 32] <= finish(nacc[c * ACC_W +: ACC_W], bmem[c]);
          fin <= 1'b1;
        end
      end
      if (fin) begin
        cls  <= best;
        done <= 1'b1;
      end
    end
  end

  // argmax over the registered logits, first maximum wins (as numpy's argmax)
  always_comb begin
    best = '0;
    for (int c = 1; c < NCLS; c++)
      if ($signed(logits[c * 32 +: 32]) > $signed(logits[best * 32 +: 32])) best = c[$clog2(NCLS) - 1 : 0];
  end

endmodule
