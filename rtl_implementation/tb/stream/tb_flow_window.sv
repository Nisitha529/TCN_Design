`timescale 1ns/1ps

// tb_flow_window -- self-checking test of rtl/stream/flow_window.sv.
//
// A reference model in the testbench applies the same rule to every record:
//   pkt_idx >= N, !last ignored
//   pkt_idx == 0        restart the row's mask and its `emitted` bit
//   pkt_idx <  N        slot[pkt_idx] = record, mask |= 1 << pkt_idx
//   emit if not yet emitted and (pkt_idx == N-1, or last with a non-empty mask):
//                       expect a window: slots where valid, zeros elsewhere
// and every window the DUT emits is compared, in order, with the expected one.
//
//   W1  one flow, N records in order -> one complete window
//   W2  random traffic over FLOW_BITS=6 (64 rows), so many logical flows reuse
//       each row: interleaved flows, dropped records (incomplete windows),
//       stray pkt_idx >= N, and random back-pressure on the output
//   W3  statistics agree with the reference counts
//   (W2 also ends flows early with `last` -- with a packet, or flush-only with
//    pkt_idx 31 -- and sends late/repeated FINs that must NOT emit again)

module tb_flow_window;
  import qos_record_pkg::*;

  parameter FLOW_BITS = 6;
  parameter N         = 8;
  parameter N_RECORDS = 6000;

  localparam ROWS = 1 << FLOW_BITS;

  logic clk = 0, rst_n;
  always #2 clk = ~clk;

  logic [REC_W - 1 : 0]      s_tdata = '0;
  logic                      s_tvalid = 0;
  wire                       s_tready;
  wire  [FLOW_BITS - 1 : 0]  m_flow_idx;
  wire  [N * SLOT_W - 1 : 0] m_window;
  wire  [N - 1 : 0]          m_valid_mask;
  wire                       m_tvalid;
  logic                      m_tready = 1;
  wire  [31 : 0]             st_records, st_windows, st_incomplete, st_ignored, st_flushed;

  flow_window #(.FLOW_BITS(FLOW_BITS), .N(N)) dut (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .m_flow_idx(m_flow_idx), .m_window(m_window), .m_valid_mask(m_valid_mask),
    .m_tvalid(m_tvalid), .m_tready(m_tready),
    .st_records(st_records), .st_windows(st_windows),
    .st_incomplete(st_incomplete), .st_ignored(st_ignored), .st_flushed(st_flushed)
  );

  int pass_cnt = 0, fail_cnt = 0;
  task automatic chk(input string name, input logic cond);
    if (cond) begin $display("    [PASS] %s", name); pass_cnt++; end
    else      begin $display("    [FAIL] %s", name); fail_cnt++; end
  endtask

  // ── reference model ──────────────────────────────────────────────────────
  logic [SLOT_W - 1 : 0]     ref_slot  [0 : ROWS - 1][0 : N - 1];
  logic [N - 1 : 0]          ref_valid [0 : ROWS - 1];
  logic                      ref_em    [0 : ROWS - 1];
  logic [N * SLOT_W - 1 : 0] exp_win   [$];
  logic [N - 1 : 0]          exp_mask  [$];
  logic [FLOW_BITS - 1 : 0]  exp_idx   [$];
  int ref_records = 0, ref_windows = 0, ref_incomplete = 0, ref_ignored = 0, ref_flushed = 0;

  task automatic ref_apply(input logic [REC_W - 1 : 0] r);
    int idx, pkt;
    bit has, last, full, emit;
    logic [N * SLOT_W - 1 : 0] w;
    idx = r[REC_W - FLOW_ID_W +: FLOW_BITS];
    pkt = rec_pkt_idx(r);
    has = (pkt < N);
    last = rec_last(r);
    ref_records++;
    if (!has && !last) begin
      ref_ignored++;
    end else begin
      if (has) begin
        if (pkt == 0) begin ref_valid[idx] = '0; ref_em[idx] = 0; end
        ref_valid[idx][pkt] = 1'b1;
        ref_slot[idx][pkt] = rec_slot(r);
      end
      full = has && (pkt == N - 1);
      emit = !ref_em[idx] && (full || (last && ref_valid[idx] != '0));
      if (emit) begin
        ref_em[idx] = 1;
        for (int k = 0; k < N; k++) w[k * SLOT_W +: SLOT_W] = ref_valid[idx][k] ? ref_slot[idx][k] : '0;
        exp_win.push_back(w); exp_mask.push_back(ref_valid[idx]); exp_idx.push_back(idx[FLOW_BITS - 1 : 0]);
        ref_windows++;
        if (ref_valid[idx] != {N{1'b1}}) ref_incomplete++;
        if (!full) ref_flushed++;
      end
    end
  endtask

  // ── output checker ───────────────────────────────────────────────────────
  int n_got = 0, n_bad = 0, n_extra = 0, n_proto = 0;
  logic held = 0; logic [N * SLOT_W - 1 : 0] held_w;
  logic [N * SLOT_W - 1 : 0] ew; logic [N - 1 : 0] em; logic [FLOW_BITS - 1 : 0] ei;
  always @(posedge clk) begin
    if (rst_n) begin
      if (held && (!m_tvalid || m_window !== held_w)) n_proto++;
      held <= m_tvalid && !m_tready; held_w <= m_window;
      if (m_tvalid && m_tready) begin
        n_got++;
        if (exp_win.size() == 0) n_extra++;
        else begin
          ew = exp_win.pop_front(); em = exp_mask.pop_front(); ei = exp_idx.pop_front();
          if (m_window !== ew || m_valid_mask !== em || m_flow_idx !== ei) n_bad++;
        end
      end
    end
  end

  // ── driver ───────────────────────────────────────────────────────────────
  task automatic send(input logic [REC_W - 1 : 0] r);
    @(negedge clk); s_tdata = r; s_tvalid = 1;
    do @(posedge clk); while (!s_tready);
    ref_apply(r);                         // accepted on this edge
    @(negedge clk); s_tvalid = 0;
  endtask

  function automatic logic [REC_W - 1 : 0] mkrec(input int idx, input int pkt, input bit last = 0);
    logic [REC_W - 1 : 0] r;
    r = '0;
    r[63 : 44] = idx;                     // flow_id (upper bits zero)
    r[43 : 39] = pkt;
    r[38 : 28] = $urandom_range(0, 1460); // size
    r[27]      = $urandom_range(0, 1);    // dir
    r[26 : 11] = $urandom;                // ipt_u
    r[10]      = $urandom_range(0, 1);    // push
    r[9]       = last;
    return r;
  endfunction

  int next_pkt [0 : ROWS - 1];
  bit stop_bp = 0;

  initial begin
    $display("\n================================================================");
    $display("  flow_window -- FLOW_BITS=%0d (rows %0d), N=%0d", FLOW_BITS, ROWS, N);
    $display("================================================================");
    for (int i = 0; i < ROWS; i++) begin ref_valid[i] = '0; ref_em[i] = 0; next_pkt[i] = 0; end
    rst_n = 0; repeat (5) @(posedge clk); @(negedge clk); rst_n = 1;

    // W1 ──────────────────────────────────────────────────────────────────
    $display("\n== W1: one flow, N records ==");
    for (int p = 0; p < N; p++) send(mkrec(5, p));
    repeat (20) @(posedge clk);
    chk("W1: exactly one window", n_got == 1 && ref_windows == 1);
    chk("W1: window, mask and flow index match", n_bad == 0 && n_extra == 0);
    chk("W1: mask is complete", ref_incomplete == 0);

    // W2 ──────────────────────────────────────────────────────────────────
    $display("\n== W2: %0d random records, interleaved flows, drops, back-pressure ==", N_RECORDS);
    fork
      begin : bp
        while (!stop_bp) begin @(negedge clk); m_tready = ($urandom_range(0, 3) != 0); end
        m_tready = 1;
      end
      begin
        for (int i = 0; i < N_RECORDS; i++) begin
          int idx, roll;
          idx = $urandom_range(0, ROWS - 1);
          roll = $urandom_range(0, 99);
          if (roll < 3) begin
            send(mkrec(idx, $urandom_range(N, 31)));         // stray pkt_idx >= N
          end else if (roll < 8) begin
            next_pkt[idx]++;                                 // a record lost upstream
          end else if (roll < 11) begin
            next_pkt[idx] = 0;                               // flow abandoned; a new one takes the row
          end else if (roll < 14) begin
            send(mkrec(idx, next_pkt[idx], 1));              // FIN carrying a packet: store, then flush
            next_pkt[idx] = 0;
          end else if (roll < 17) begin
            send(mkrec(idx, 31, 1));                         // FIN with no payload: flush only
            next_pkt[idx] = 0;                               // (repeats / late FINs must not re-emit)
          end else begin
            send(mkrec(idx, next_pkt[idx]));
            next_pkt[idx]++;
          end
          if (next_pkt[idx] >= N) next_pkt[idx] = 0;         // window done; next flow on this row
        end
        repeat (50) @(posedge clk);
        stop_bp = 1;
      end
    join
    repeat (50) @(posedge clk);
    $display("      %0d windows (%0d incomplete, %0d flushed by last), %0d stray records ignored",
             ref_windows, ref_incomplete, ref_flushed, ref_ignored);
    chk("W2: every expected window emitted", n_got == ref_windows && exp_win.size() == 0);
    chk("W2: every window matches the reference (slots, mask, flow index)", n_bad == 0);
    chk("W2: no unexpected windows", n_extra == 0);
    chk("W2: output held stable under back-pressure", n_proto == 0);
    chk("W2: the run included incomplete windows", ref_incomplete > 0);

    // W3 ──────────────────────────────────────────────────────────────────
    $display("\n== W3: statistics ==");
    chk("W3: st_records",    st_records    == ref_records);
    chk("W3: st_windows",    st_windows    == ref_windows);
    chk("W3: st_incomplete", st_incomplete == ref_incomplete);
    chk("W3: st_ignored",    st_ignored    == ref_ignored);
    chk("W3: st_flushed",    st_flushed    == ref_flushed);
    chk("W3: the run included flushed (short-flow) windows", ref_flushed > 0);

    $display("\n================================================================");
    $display("  Results: %0d passed, %0d failed  (total %0d)", pass_cnt, fail_cnt, pass_cnt + fail_cnt);
    $display("================================================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else               $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #5000000; $display("[TIMEOUT]"); $finish; end

endmodule
