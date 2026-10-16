`timescale 1ns/1ps

// qos_tcn_engine -- classify one flow window: TCN v2's compute core.
//
//   flow_window ─► window ─► qos_input_stage ─► block1 ─► block2 ─► block3 ─► win_head ─► {flow, class}
//                            lookup tables      dilation D1    D2       D3      flatten + argmax
//
// Bit-exact with IntModel.int_forward (qos_tcn/quant.py); the weights and
// tables are hex files written by qos_tcn/export_rtl.py into WDIR. One flow is
// in flight at a time in this version (s_tready is low while it computes);
// pipelining the blocks across flows is the next throughput step.
//
// Cycles per flow, roughly:
//   N + 1                                          input stage
//   + per block: N*(C/P)*CI*3 (conv1, res in parallel) + N*(C/P)*C*3 (conv2)
//   + C3*N                                         head
// e.g. N = 8, channels 32/32/64, P = 16/16/32: ~10.6k cycles = 42 us at 250 MHz.

module qos_tcn_engine #(
  parameter N    = 8,
  parameter ES   = 8, parameter EI = 4, parameter ED = 2, parameter EP = 1,
  parameter C1   = 32, parameter C2 = 32, parameter C3 = 64,
  parameter D1   = 1,  parameter D2 = 2,  parameter D3 = 4,
  parameter K    = 3,
  parameter P1   = 16, parameter P2 = 16, parameter P3 = 32,
  parameter NCLS = 5,
  parameter FLOW_BITS = 16,
  parameter SLOT_W    = 32,
  parameter DW        = 16,
  parameter WDIR      = "."
)(
  input  wire                        clk,
  input  wire                        rst_n,

  // from flow_window
  input  wire [FLOW_BITS - 1 : 0]    s_flow_idx,
  input  wire [N * SLOT_W - 1 : 0]   s_window,
  input  wire [N - 1 : 0]            s_valid_mask,
  input  wire                        s_tvalid,
  output wire                        s_tready,

  // result
  output reg  [FLOW_BITS - 1 : 0]    m_flow_idx,
  output wire [$clog2(NCLS) - 1 : 0] m_class,
  output wire [NCLS * 32 - 1 : 0]    m_logits,
  output reg                         m_tvalid,
  input  wire                        m_tready
);

  localparam C0 = ES + EI + ED + EP;

  reg                        busy;
  reg [N * SLOT_W - 1 : 0]   r_window;
  reg [N - 1 : 0]            r_mask;
  reg                        go;

  wire [N * C0 * DW - 1 : 0] a0;
  wire [N * C1 * DW - 1 : 0] a1;
  wire [N * C2 * DW - 1 : 0] a2;
  wire [N * C3 * DW - 1 : 0] a3;
  wire d0, d1, d2, d3, dh;

  assign s_tready = !busy;

  qos_input_stage #(.N(N), .ES(ES), .EI(EI), .ED(ED), .EP(EP), .DW(DW), .SLOT_W(SLOT_W),
    .SIZE_FILE({WDIR, "/emb_size.hex"}), .IPT_FILE({WDIR, "/emb_ipt.hex"}),
    .DIR_FILE({WDIR, "/emb_dir.hex"}),   .PUSH_FILE({WDIR, "/emb_push.hex"}))
    in0 (.clk(clk), .rst_n(rst_n), .start(go), .slots(r_window), .mask(r_mask), .act(a0), .done(d0));

  win_block #(.CI(C0), .CO(C1), .K(K), .D(D1), .N(N), .P(P1), .DW(DW),
    .W1_FILE({WDIR, "/b1_c1_w.hex"}), .B1_FILE({WDIR, "/b1_c1_b.hex"}),
    .W2_FILE({WDIR, "/b1_c2_w.hex"}), .B2_FILE({WDIR, "/b1_c2_b.hex"}),
    .RW_FILE({WDIR, "/b1_res_w.hex"}), .RB_FILE({WDIR, "/b1_res_b.hex"}))
    blk1 (.clk(clk), .rst_n(rst_n), .start(d0), .x(a0), .y(a1), .done(d1));

  win_block #(.CI(C1), .CO(C2), .K(K), .D(D2), .N(N), .P(P2), .DW(DW),
    .W1_FILE({WDIR, "/b2_c1_w.hex"}), .B1_FILE({WDIR, "/b2_c1_b.hex"}),
    .W2_FILE({WDIR, "/b2_c2_w.hex"}), .B2_FILE({WDIR, "/b2_c2_b.hex"}),
    .RW_FILE({WDIR, "/b2_res_w.hex"}), .RB_FILE({WDIR, "/b2_res_b.hex"}))
    blk2 (.clk(clk), .rst_n(rst_n), .start(d1), .x(a1), .y(a2), .done(d2));

  win_block #(.CI(C2), .CO(C3), .K(K), .D(D3), .N(N), .P(P3), .DW(DW),
    .W1_FILE({WDIR, "/b3_c1_w.hex"}), .B1_FILE({WDIR, "/b3_c1_b.hex"}),
    .W2_FILE({WDIR, "/b3_c2_w.hex"}), .B2_FILE({WDIR, "/b3_c2_b.hex"}),
    .RW_FILE({WDIR, "/b3_res_w.hex"}), .RB_FILE({WDIR, "/b3_res_b.hex"}))
    blk3 (.clk(clk), .rst_n(rst_n), .start(d2), .x(a2), .y(a3), .done(d3));

  win_head #(.C(C3), .N(N), .NCLS(NCLS), .DW(DW),
    .W_FILE({WDIR, "/head_w.hex"}), .B_FILE({WDIR, "/head_b.hex"}))
    head (.clk(clk), .rst_n(rst_n), .start(d3), .h(a3), .logits(m_logits), .cls(m_class), .done(dh));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; go <= 1'b0; m_tvalid <= 1'b0;
    end else begin
      go <= 1'b0;
      if (s_tvalid && s_tready) begin
        r_window   <= s_window;
        r_mask     <= s_valid_mask;
        m_flow_idx <= s_flow_idx;
        busy       <= 1'b1;
        go         <= 1'b1;
      end
      if (dh) m_tvalid <= 1'b1;
      if (m_tvalid && m_tready) begin
        m_tvalid <= 1'b0;
        busy     <= 1'b0;
      end
    end
  end

endmodule
