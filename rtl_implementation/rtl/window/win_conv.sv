`timescale 1ns/1ps

// win_conv -- one dilated causal convolution over a whole window, P output
// channels at a time.
//
// Bit-exact with IntModel.conv in qos_tcn/quant.py:
//   acc[o]   = sum_{i,k} w[o][i][k] * x[t - (K-1-k)*D][i]    (x before 0 is 0)
//   y[t][o]  = sat16((acc >>> FRAC) + b[o]),  then ReLU if RELU
// acc is ACC_W bits; the golden model asserts real data never needs more.
//
// Layout (position-major, DW bits per value):
//   x[(t*CI + i)*DW +: DW]      y[(t*CO + o)*DW +: DW]
// Weight memory: one word per (output group, i, k), P lanes wide, lane p at
// the LSB end holding w[og*P + p][i][k]:
//   address = (og*CI + i)*K + k,   word = {lane P-1, ..., lane 0}
// (written by qos_tcn/export_rtl.py; a runtime-load port comes later).
//
// Timing: N * (CO/P) * CI * K cycles plus a 2-cycle pipeline from start to
// done. x must be held stable from start to done.

module win_conv #(
  parameter CI     = 4,
  parameter CO     = 8,
  parameter K      = 3,
  parameter D      = 1,
  parameter N      = 8,
  parameter P      = 4,             // parallel output channels; CO % P == 0
  parameter RELU   = 1,
  parameter DW     = 16,
  parameter ACC_W  = 32,
  parameter FRAC   = 8,
  parameter W_FILE = "w.hex",
  parameter B_FILE = "b.hex"
)(
  input  wire                       clk,
  input  wire                       rst_n,
  input  wire                       start,
  input  wire [N * CI * DW - 1 : 0] x,
  output reg  [N * CO * DW - 1 : 0] y,
  output reg                        done,
  output wire                       busy
);

  localparam NG     = CO / P;                      // output groups
  localparam WDEPTH = NG * CI * K;
  localparam WA_W   = (WDEPTH > 1) ? $clog2(WDEPTH) : 1;
  localparam TW     = $clog2(N + 1);
  localparam GW     = $clog2(NG + 1);
  localparam IW     = $clog2(CI + 1);
  localparam KW     = $clog2(K + 1);
  localparam signed [ACC_W : 0] YMAX =  (1 <<< (DW - 1)) - 1;
  localparam signed [ACC_W : 0] YMIN = -(1 <<< (DW - 1));

  // ── parameters ───────────────────────────────────────────────────────────
  reg [P * DW - 1 : 0]    wmem [0 : WDEPTH - 1];
  reg signed [DW - 1 : 0] bmem [0 : CO - 1];
  initial begin
    $readmemh(W_FILE, wmem);
    $readmemh(B_FILE, bmem);
  end

  // ── declarations (all before use) ────────────────────────────────────────
  reg            run;
  reg [TW - 1:0] t;
  reg [GW - 1:0] og;
  reg [IW - 1:0] i;
  reg [KW - 1:0] k;

  reg                     b_v, b_first, b_last;
  reg [P * DW - 1 : 0]    b_w;
  reg signed [DW - 1 : 0] b_x;
  reg [TW - 1 : 0]        b_t;
  reg [GW - 1 : 0]        b_og;

  reg [P * ACC_W - 1 : 0] acc;                     // packed: lane p at [p*ACC_W +: ACC_W]

  assign busy = run || b_v;

  // ── stage A: loop counters -> weight address and input tap ──────────────
  wire                a_first = (i == 0) && (k == 0);
  wire                a_last  = (i == CI - 1) && (k == K - 1);
  wire [WA_W - 1 : 0] a_waddr = (og * CI + i) * K + k;
  // how far back this tap reads; t < shift means causal zero padding
  wire [31 : 0]       a_shift = (K - 1 - k) * D;
  wire                a_pad   = ({{(32 - TW){1'b0}}, t} < a_shift);
  wire [31 : 0]       a_src   = t - a_shift;

  // ── stage B: registered weight word, input value, control ───────────────
  always_ff @(posedge clk) begin
    b_w     <= wmem[a_waddr];                          // registered read: block RAM
    b_x     <= a_pad ? '0 : $signed(x[(a_src * CI + i) * DW +: DW]);
    b_t     <= t;
    b_og    <= og;
    b_first <= a_first;
    b_last  <= a_last;
  end

  // ── stage C: P multiply-accumulate lanes ────────────────────────────────
  wire [P * ACC_W - 1 : 0] nacc;
  genvar gp;
  generate
    for (gp = 0; gp < P; gp = gp + 1) begin : lane
      wire signed [ACC_W - 1 : 0] prod = $signed(b_w[gp * DW +: DW]) * b_x;
      assign nacc[gp * ACC_W +: ACC_W] = b_first ? prod : $signed(acc[gp * ACC_W +: ACC_W]) + prod;
    end
  endgenerate

  function automatic [DW - 1 : 0] finish(input [ACC_W - 1 : 0] a, input [DW - 1 : 0] bias);
    reg signed [ACC_W : 0] v;
    v = ($signed(a) >>> FRAC) + $signed(bias);
    if (v > YMAX) v = YMAX;
    if (v < YMIN) v = YMIN;
    if (RELU && v < 0) v = 0;
    finish = v[DW - 1 : 0];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; done <= 1'b0; b_v <= 1'b0;
      t <= '0; og <= '0; i <= '0; k <= '0;
    end else begin
      done <= 1'b0;
      b_v  <= run;

      if (start && !run && !b_v) begin
        run <= 1'b1;
        t <= '0; og <= '0; i <= '0; k <= '0;
      end else if (run) begin
        if (k != K - 1)         k <= k + 1'b1;
        else begin
          k <= '0;
          if (i != CI - 1)      i <= i + 1'b1;
          else begin
            i <= '0;
            if (og != NG - 1)   og <= og + 1'b1;
            else begin
              og <= '0;
              if (t != N - 1)   t <= t + 1'b1;
              else              run <= 1'b0;           // last tap issued
            end
          end
        end
      end

      if (b_v) begin
        acc <= nacc;
        if (b_last) begin
          for (int p = 0; p < P; p++) begin
            y[(b_t * CO + b_og * P + p) * DW +: DW] <= finish(nacc[p * ACC_W +: ACC_W], bmem[b_og * P + p]);
          end
          if (b_t == N - 1 && b_og == NG - 1) done <= 1'b1;
        end
      end
    end
  end

  initial begin
    if (CO % P != 0) $error("win_conv: CO (%0d) must be a multiple of P (%0d)", CO, P);
  end

endmodule
