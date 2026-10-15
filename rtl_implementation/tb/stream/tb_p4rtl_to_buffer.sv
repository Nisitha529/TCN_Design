`timescale 1ns/1ps

// tb_p4rtl_to_buffer -- the real P4 pipeline feeding the feature buffer.
//
//   feprobe_top (p4rtl-generated, Compiler_design/.../generated/feprobe)
//     .tcn_feed_t* ──► feature_buffer ──► a "TCN" consumer on its own clock
//
// feprobe's tcn_feed record carries eth.dst[15:0] in bits [31:16]; every
// packet here gets a distinct dst, so it doubles as a sequence number and the
// consumer can tell order, loss and duplication apart.
//
// Two scenarios, picked with EXPECT_DROPS (see run_feature_buffer.sh):
//   EXPECT_DROPS=0  deep buffer, consumer slower than the offered rate. The
//                   buffer absorbs the difference: every record arrives, in
//                   order, and p4rtl's `dropped` counter stays 0.
//   EXPECT_DROPS=1  tiny buffer, consumer nearly stalled. Records are lost --
//                   but only at p4rtl's staging ring, never in the buffer, so
//                   the accounting closes exactly:
//                       records received + p4rtl dropped == packets sent
//                   and what does arrive is still in order with no duplicates.
// In both, every PACKET is forwarded: the buffer never stalls the packet path.

module tb_p4rtl_to_buffer;

  parameter ADDR_WIDTH   = 8;
  parameter EXPECT_DROPS = 0;
  parameter TREADY_PCT   = 50;       // consumer's chance of being ready, per cycle
  parameter N_PKTS       = 200;
  parameter real S_PERIOD = 4.0;     // p4rtl, 250 MHz
  parameter real M_PERIOD = 7.3;     // TCN

  localparam int TB_BEAT_BYTES = 32;
  localparam int TB_AXI_DATA_W = TB_BEAT_BYTES * 8;
  localparam int REC_W         = 64;

  // feprobe register map (generated/feprobe/feprobe_cp_map.json)
  localparam int W_FWD_IDX = 0, W_FWD_ACT = 1, W_FWD_KEY = 2, W_FWD_PORT = 3, W_FWD_COMMIT = 4;
  localparam int W_FEED_PUSHED = 66, W_FEED_DROPPED = 67;

  logic s_clk = 0, m_clk = 0;
  logic s_rst_n, m_rst_n;
  always #(S_PERIOD / 2) s_clk = ~s_clk;
  always #(M_PERIOD / 2) m_clk = ~m_clk;

  // ── p4rtl pipeline ───────────────────────────────────────────────────────
  logic [TB_AXI_DATA_W-1:0] s_axis_tdata;
  logic [TB_BEAT_BYTES-1:0] s_axis_tkeep;
  logic s_axis_tvalid = 0, s_axis_tready, s_axis_tlast = 0;
  logic [TB_AXI_DATA_W-1:0] m_axis_tdata;
  logic [TB_BEAT_BYTES-1:0] m_axis_tkeep;
  logic m_axis_tvalid, m_axis_tready = 1'b1, m_axis_tlast;

  logic [15:0] s_axil_awaddr = 0; logic s_axil_awvalid = 0, s_axil_awready;
  logic [31:0] s_axil_wdata = 0;  logic [3:0] s_axil_wstrb = 0;
  logic s_axil_wvalid = 0, s_axil_wready; logic [1:0] s_axil_bresp;
  logic s_axil_bvalid, s_axil_bready = 1'b1;
  logic [15:0] s_axil_araddr = 0; logic s_axil_arvalid = 0, s_axil_arready;
  logic [31:0] s_axil_rdata;  logic [1:0] s_axil_rresp;
  logic s_axil_rvalid, s_axil_rready = 1'b1;

  wire  [REC_W-1:0] feed_tdata;
  wire              feed_tvalid, feed_tready;
  logic [15:0] gated_feed_tdata; logic gated_feed_tvalid;
  logic [15:0] out_meta_flow_id, out_meta_seen;
  logic  [7:0] out_meta_dir;
  logic  [8:0] out_std_meta_egress_port;

  feprobe_top p4 (
    .clk(s_clk), .rst_n(s_rst_n),
    .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
    .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
    .s_axil_awaddr(s_axil_awaddr), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb),
    .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),
    .tcn_feed_tdata(feed_tdata), .tcn_feed_tvalid(feed_tvalid), .tcn_feed_tready(feed_tready),
    .gated_feed_tdata(gated_feed_tdata), .gated_feed_tvalid(gated_feed_tvalid),
    .gated_feed_tready(1'b1),
    .out_meta_flow_id(out_meta_flow_id), .out_meta_seen(out_meta_seen),
    .out_meta_dir(out_meta_dir),
    .out_std_meta_egress_port(out_std_meta_egress_port)
  );

  // ── feature buffer ───────────────────────────────────────────────────────
  wire [REC_W-1:0]      rec_tdata;
  wire                  rec_tvalid;
  logic                 rec_tready = 0;
  wire [ADDR_WIDTH : 0] occ, hiwater;
  wire [31:0]           stall_cycles;

  feature_buffer #(
    .DATA_WIDTH     (REC_W),
    .ADDR_WIDTH     (ADDR_WIDTH)
  ) buffer (
    .s_clk          (s_clk),
    .s_rst_n        (s_rst_n),
    .s_axis_tdata   (feed_tdata),
    .s_axis_tvalid  (feed_tvalid),
    .s_axis_tready  (feed_tready),
    .s_stats_clear  (1'b0),
    .s_occupancy    (occ),
    .s_hiwater      (hiwater),
    .s_stall_cycles (stall_cycles),
    .m_clk          (m_clk),
    .m_rst_n        (m_rst_n),
    .m_axis_tdata   (rec_tdata),
    .m_axis_tvalid  (rec_tvalid),
    .m_axis_tready  (rec_tready)
  );

  int pass_cnt = 0, fail_cnt = 0;
  task automatic chk(input string name, input logic cond);
    if (cond) begin $display("    [PASS] %s", name); pass_cnt++; end
    else      begin $display("    [FAIL] %s", name); fail_cnt++; end
  endtask

  // ── "TCN" consumer: random tready, checks the sequence ───────────────────
  int n_recs = 0, n_out_of_order = 0, n_dupes = 0;
  int last_seq = -1;
  bit consumer_on = 0;
  always @(posedge m_clk) begin
    if (m_rst_n && rec_tvalid && rec_tready) begin
      int seq;
      seq = int'(rec_tdata[31:16]);
      n_recs++;
      if (seq == last_seq)      n_dupes++;
      else if (seq < last_seq)  n_out_of_order++;
      last_seq = seq;
    end
  end
  always @(posedge m_clk) begin
    #0.1;
    rec_tready = consumer_on && ($urandom_range(0, 99) < TREADY_PCT);
  end

  // ── packets out of the p4rtl pipeline ────────────────────────────────────
  int out_pkts = 0;
  always @(posedge s_clk)
    if (s_rst_n && m_axis_tvalid && m_axis_tready && m_axis_tlast) out_pkts++;

  // ── AXI4-Lite + frame drivers (same shape as feprobe's own testbench) ────
  task automatic axil_write(input int word_addr, input logic [31:0] data);
    bit aw_done, w_done;
    @(negedge s_clk);
    s_axil_awaddr = word_addr * 4; s_axil_awvalid = 1'b1;
    s_axil_wdata = data; s_axil_wstrb = 4'hF; s_axil_wvalid = 1'b1;
    aw_done = 1'b0; w_done = 1'b0;
    while (!aw_done || !w_done) begin
      @(posedge s_clk); #0.1;
      if (!aw_done && s_axil_awready) aw_done = 1'b1;
      if (!w_done && s_axil_wready)   w_done  = 1'b1;
    end
    @(negedge s_clk); s_axil_awvalid = 1'b0; s_axil_wvalid = 1'b0;
  endtask

  task automatic axil_read(input int word_addr, output logic [31:0] data);
    bit accepted;
    @(negedge s_clk);
    s_axil_araddr = word_addr * 4; s_axil_arvalid = 1'b1;
    accepted = 1'b0;
    while (!accepted) begin @(posedge s_clk); if (s_axil_arready) accepted = 1'b1; end
    @(negedge s_clk); s_axil_arvalid = 1'b0;
    @(posedge s_clk); data = s_axil_rdata;
  endtask

  // 64-byte frame, ethertype 0x0801 (forwarded), dst[15:0] = seq
  task automatic send_frame(input [15:0] seq);
    logic [TB_AXI_DATA_W-1:0] beat;
    logic [TB_BEAT_BYTES-1:0] keep;
    byte pkt[$];
    pkt.delete();
    for (int i = 0; i < 64; i++) pkt.push_back(8'(i));
    pkt[4] = seq[15:8]; pkt[5] = seq[7:0];
    pkt[12] = 8'h08;    pkt[13] = 8'h01;
    for (int b = 0; b < 2; b++) begin
      beat = '0; keep = '1;
      for (int i = 0; i < TB_BEAT_BYTES; i++) beat[i*8 +: 8] = pkt[b*TB_BEAT_BYTES + i];
      @(negedge s_clk);
      s_axis_tdata = beat; s_axis_tkeep = keep;
      s_axis_tvalid = 1'b1; s_axis_tlast = (b == 1);
      @(posedge s_clk);
      while (!s_axis_tready) @(posedge s_clk);
    end
    @(negedge s_clk); s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
  endtask

  logic [31:0] pushed, dropped;

  initial begin
    $display("\n================================================================");
    $display("  p4rtl feprobe -> feature_buffer  depth=%0d  consumer ready %0d%%  (%s)",
             1 << ADDR_WIDTH, TREADY_PCT, EXPECT_DROPS ? "drops expected" : "no drops expected");
    $display("================================================================");
    s_rst_n = 0; m_rst_n = 0;
    repeat (6) @(posedge s_clk);
    repeat (6) @(posedge m_clk);
    #0.1; s_rst_n = 1; m_rst_n = 1;
    repeat (6) @(posedge s_clk);

    // forward ethertype 0x0801 to port 5
    axil_write(W_FWD_IDX, 0); axil_write(W_FWD_ACT, 1); axil_write(W_FWD_KEY, 16'h0801);
    axil_write(W_FWD_PORT, 5); axil_write(W_FWD_COMMIT, 1);
    repeat (6) @(posedge s_clk);

    consumer_on = 1;
    for (int i = 0; i < N_PKTS; i++) send_frame(16'(i));   // back to back

    // let the pipeline finish, then let the consumer drain everything
    repeat (200) @(posedge s_clk);
    begin
      int idle = 0;
      while (idle < 200) begin
        @(posedge m_clk);
        if (rec_tvalid || occ != 0) idle = 0; else idle++;
      end
    end

    axil_read(W_FEED_PUSHED,  pushed);
    axil_read(W_FEED_DROPPED, dropped);
    $display("      packets sent %0d, forwarded %0d", N_PKTS, out_pkts);
    $display("      p4rtl pushed %0d, dropped %0d; records received %0d", pushed, dropped, n_recs);
    $display("      buffer high watermark %0d of %0d, stall cycles %0d",
             hiwater, 1 << ADDR_WIDTH, stall_cycles);

    chk("every packet forwarded (the buffer never stalls the packet path)", out_pkts == N_PKTS);
    chk("records received == p4rtl pushed (nothing lost inside the buffer)", n_recs == pushed);
    chk("received + p4rtl dropped == packets sent (accounting closes)",
        n_recs + dropped == N_PKTS);
    chk("no duplicated record", n_dupes == 0);
    chk("records in order", n_out_of_order == 0);
    if (EXPECT_DROPS) begin
      chk("drops happened, at p4rtl's staging ring", dropped > 0);
      chk("the buffer pushed back (stall cycles counted)", stall_cycles > 0);
      chk("the buffer filled to its depth", hiwater == (1 << ADDR_WIDTH));
    end else begin
      chk("no drops: the buffer absorbed the rate difference", dropped == 0 && n_recs == N_PKTS);
      chk("the buffer was actually used (high watermark > 1)", hiwater > 1);
    end

    $display("\n================================================================");
    $display("  Results: %0d passed, %0d failed  (total %0d)", pass_cnt, fail_cnt, pass_cnt + fail_cnt);
    $display("================================================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else               $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #2000000; $display("[TIMEOUT]"); $finish; end

endmodule
