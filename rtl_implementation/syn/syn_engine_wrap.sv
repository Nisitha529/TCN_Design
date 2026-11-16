`timescale 1ns/1ps

// syn_engine_wrap -- a synthesis harness for qos_tcn_engine.
//
// The engine has ~450 data ports, more than a device has pins and pointless as
// pins anyway. This wrapper keeps every bit of the engine's logic alive without
// exposing them:
//   * inputs come from a free-running 64-bit LFSR, so no input is a constant
//     the tools could propagate;
//   * every output bit is XOR-reduced into one registered pin, so no output is
//     unused logic the tools could delete.
// Only clk, rst_n and `obs` reach the device's pins. The numbers this gives are
// the engine's own cost plus a few dozen flip-flops for the LFSR and the XOR.
//
// Not for simulation: the outputs are meaningless. Bit-exact behaviour is tested
// by tb/window/run_window_tests.sh.

module syn_engine_wrap #(
  parameter N    = 8,
  parameter C1   = 32, parameter C2 = 32, parameter C3 = 64,
  parameter D1   = 1,  parameter D2 = 2,  parameter D3 = 4,
  parameter P1   = 16, parameter P2 = 16, parameter P3 = 32,
  parameter NCLS = 5,
  parameter FLOW_BITS = 16,
  parameter WDIR = "weights/qos_N8"
)(
  input  wire clk,
  input  wire rst_n,
  output reg  obs
);

  localparam SLOT_W = 32;

  // ── stimulus: a maximal-length 64-bit LFSR (x^64 + x^63 + x^61 + x^60 + 1) ──
  reg [63:0] lfsr;
  always_ff @(posedge clk) begin
    if (!rst_n) lfsr <= 64'hACE1_2468_1357_BDF0;
    else        lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};
  end

  // spread the LFSR across the window, rotating it so the slots differ
  wire [N * SLOT_W - 1 : 0] window;
  genvar g;
  generate
    for (g = 0; g < N; g = g + 1) begin : fill
      assign window[g * SLOT_W +: SLOT_W] = {lfsr[(g * 7) % 32 +: 32]};
    end
  endgenerate

  wire [FLOW_BITS - 1 : 0]    m_flow_idx;
  wire [$clog2(NCLS) - 1 : 0] m_class;
  wire [NCLS * 32 - 1 : 0]    m_logits;
  wire                        m_tvalid, s_tready;

  qos_tcn_engine #(
    .N(N), .C1(C1), .C2(C2), .C3(C3), .D1(D1), .D2(D2), .D3(D3),
    .P1(P1), .P2(P2), .P3(P3), .NCLS(NCLS), .FLOW_BITS(FLOW_BITS), .WDIR(WDIR)
  ) eng (
    .clk(clk), .rst_n(rst_n),
    .s_flow_idx(lfsr[FLOW_BITS - 1 : 0]), .s_window(window), .s_valid_mask(lfsr[40 +: N]),
    .s_tvalid(1'b1), .s_tready(s_tready),
    .m_flow_idx(m_flow_idx), .m_class(m_class), .m_logits(m_logits),
    .m_tvalid(m_tvalid), .m_tready(1'b1)
  );

  always_ff @(posedge clk) begin
    obs <= ^{m_flow_idx, m_class, m_logits, m_tvalid, s_tready};
  end

endmodule
