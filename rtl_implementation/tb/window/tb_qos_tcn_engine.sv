`timescale 1ns/1ps

// tb_qos_tcn_engine -- the whole TCN v2 compute core against the golden model,
// on real CESNET flows with the trained weights (qos_tcn/export_rtl.py).
//
// For every test flow: drive its window into the engine and compare the class
// AND all logits with IntModel.int_forward's, bit for bit. Also reports cycles
// per flow and exercises output back-pressure.
//
// Parameters must match WDIR/engine_params.txt (run_window_tests.sh passes them).

module tb_qos_tcn_engine;

  parameter N = 4, ES = 8, EI = 4, ED = 2, EP = 1;
  parameter C1 = 32, C2 = 32, C3 = 64, D1 = 1, D2 = 2, D3 = 4, K = 3;
  parameter P1 = 16, P2 = 16, P3 = 32, NCLS = 5;
  parameter NV = 200;
  parameter WDIR = ".";
  localparam SLOT_W = 32, FLOW_BITS = 16, CW = $clog2(NCLS);

  logic clk = 0, rst_n = 0;
  always #2 clk = ~clk;

  logic [FLOW_BITS - 1 : 0]  s_flow_idx;
  logic [N * SLOT_W - 1 : 0] s_window;
  logic [N - 1 : 0]          s_valid_mask;
  logic                      s_tvalid = 0;
  wire                       s_tready;
  wire  [FLOW_BITS - 1 : 0]  m_flow_idx;
  wire  [CW - 1 : 0]         m_class;
  wire  [NCLS * 32 - 1 : 0]  m_logits;
  wire                       m_tvalid;
  logic                      m_tready = 0;

  qos_tcn_engine #(.N(N), .ES(ES), .EI(EI), .ED(ED), .EP(EP), .C1(C1), .C2(C2), .C3(C3),
                   .D1(D1), .D2(D2), .D3(D3), .K(K), .P1(P1), .P2(P2), .P3(P3), .NCLS(NCLS),
                   .FLOW_BITS(FLOW_BITS), .WDIR(WDIR)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_flow_idx(s_flow_idx), .s_window(s_window), .s_valid_mask(s_valid_mask),
    .s_tvalid(s_tvalid), .s_tready(s_tready),
    .m_flow_idx(m_flow_idx), .m_class(m_class), .m_logits(m_logits),
    .m_tvalid(m_tvalid), .m_tready(m_tready));

  logic [N * SLOT_W - 1 : 0] tv_win   [0 : NV - 1];
  logic [N - 1 : 0]          tv_mask  [0 : NV - 1];
  logic [CW - 1 : 0]         tv_cls   [0 : NV - 1];
  logic [NCLS * 32 - 1 : 0]  tv_log   [0 : NV - 1];
  initial begin
    $readmemh({WDIR, "/tv_window.hex"}, tv_win);
    $readmemh({WDIR, "/tv_mask.hex"},   tv_mask);
    $readmemh({WDIR, "/tv_class.hex"},  tv_cls);
    $readmemh({WDIR, "/tv_logits.hex"}, tv_log);
  end

  int bad_cls = 0, bad_log = 0, bad_idx = 0, cycles = 0, maxc = 0;
  initial begin
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    for (int v = 0; v < NV; v++) begin
      @(negedge clk);
      s_window = tv_win[v]; s_valid_mask = tv_mask[v]; s_flow_idx = v; s_tvalid = 1;
      do @(posedge clk); while (!s_tready);
      @(negedge clk); s_tvalid = 0;
      cycles = 0;
      while (!m_tvalid) begin @(posedge clk); cycles++; end
      if (cycles > maxc) maxc = cycles;
      repeat (v % 3) @(posedge clk);                 // hold the result: back-pressure
      @(negedge clk);
      if (m_class !== tv_cls[v]) begin
        bad_cls++;
        if (bad_cls <= 5) $display("    class mismatch flow %0d: got %0d want %0d", v, m_class, tv_cls[v]);
      end
      if (m_logits !== tv_log[v]) begin
        bad_log++;
        if (bad_log <= 5)
          for (int c = 0; c < NCLS; c++)
            $display("    flow %0d logit %0d: got %0d want %0d", v, c,
                     $signed(m_logits[c * 32 +: 32]), $signed(tv_log[v][c * 32 +: 32]));
      end
      if (m_flow_idx !== v) bad_idx++;
      m_tready = 1; @(negedge clk); m_tready = 0;
    end
    $display("qos_tcn_engine N=%0d %0d/%0d/%0d P=%0d/%0d/%0d: class exact %0d/%0d, logits exact %0d/%0d, flow index ok %0d/%0d, %0d cycles/flow",
             N, C1, C2, C3, P1, P2, P3, NV - bad_cls, NV, NV - bad_log, NV, NV - bad_idx, NV, maxc);
    $display("  Results: %0d passed, %0d failed", (bad_cls + bad_log + bad_idx == 0) ? 1 : 0,
             (bad_cls + bad_log + bad_idx == 0) ? 0 : 1);
    $finish;
  end

  initial begin #200000000; $display("[TIMEOUT]"); $finish; end

endmodule
