`timescale 1ns/1ps

// tb_feature_buffer -- self-checking test of rtl/stream/feature_buffer.sv
// across two unrelated clocks.
//
//   B1  one record goes through unchanged
//   B2  random traffic both sides (random tvalid gaps, random tready):
//       every record comes out exactly once, in order, unmodified, and the
//       stream protocol holds on the output (tvalid/tdata stable until taken)
//   B3  consumer stalled: the buffer takes DEPTH + 1 records (the RAM plus the
//       output register), then holds s_axis_tready low; occupancy and the high
//       watermark read DEPTH and stall cycles are counted. Then it drains in
//       order.
//   B4  s_stats_clear zeroes the high watermark and the stall counter
//
// Run with different clock ratios and depths (see run_feature_buffer.sh):
//   reader faster than writer, reader slower, and ADDR_WIDTH=2 so the
//   pointers wrap -- and the Gray full/empty compares are exercised -- often.

module tb_feature_buffer;

  parameter DATA_WIDTH = 128;
  parameter ADDR_WIDTH = 4;
  parameter real S_PERIOD = 4.0;     // p4rtl side, e.g. 250 MHz
  parameter real M_PERIOD = 3.1;     // TCN side
  parameter N_RANDOM   = 2000;

  localparam DEPTH = 1 << ADDR_WIDTH;

  logic                      s_clk = 0, m_clk = 0;
  logic                      s_rst_n, m_rst_n;

  logic [DATA_WIDTH - 1 : 0] s_axis_tdata = '0;
  logic                      s_axis_tvalid = 0;
  wire                       s_axis_tready;
  logic                      s_stats_clear = 0;
  wire  [ADDR_WIDTH     : 0] s_occupancy;
  wire  [ADDR_WIDTH     : 0] s_hiwater;
  wire  [31 : 0]             s_stall_cycles;

  wire  [DATA_WIDTH - 1 : 0] m_axis_tdata;
  wire                       m_axis_tvalid;
  logic                      m_axis_tready = 0;

  always #(S_PERIOD / 2) s_clk = ~s_clk;
  always #(M_PERIOD / 2) m_clk = ~m_clk;

  feature_buffer #(
    .DATA_WIDTH     (DATA_WIDTH),
    .ADDR_WIDTH     (ADDR_WIDTH)
  ) dut (
    .s_clk          (s_clk),
    .s_rst_n        (s_rst_n),
    .s_axis_tdata   (s_axis_tdata),
    .s_axis_tvalid  (s_axis_tvalid),
    .s_axis_tready  (s_axis_tready),
    .s_stats_clear  (s_stats_clear),
    .s_occupancy    (s_occupancy),
    .s_hiwater      (s_hiwater),
    .s_stall_cycles (s_stall_cycles),
    .m_clk          (m_clk),
    .m_rst_n        (m_rst_n),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tready  (m_axis_tready)
  );

  int pass_cnt = 0, fail_cnt = 0;
  task automatic chk(input string name, input logic cond);
    if (cond) begin $display("    [PASS] %s", name); pass_cnt++; end
    else      begin $display("    [FAIL] %s", name); fail_cnt++; end
  endtask

  // ── scoreboard ───────────────────────────────────────────────────────────
  // Expected records are queued at the WRITE handshake and compared at the
  // READ handshake, so order, loss and duplication are all caught.
  logic [DATA_WIDTH - 1 : 0] expected [$];
  int n_in = 0, n_out = 0, n_mismatch = 0, n_unexpected = 0;

  always @(posedge s_clk) begin
    if (s_rst_n && s_axis_tvalid && s_axis_tready) begin
      expected.push_back(s_axis_tdata);
      n_in++;
    end
  end

  logic [DATA_WIDTH - 1 : 0] exp_head;
  always @(posedge m_clk) begin
    if (m_rst_n && m_axis_tvalid && m_axis_tready) begin
      n_out++;
      if (expected.size() == 0) begin
        n_unexpected++;
      end else begin
        exp_head = expected.pop_front();
        if (m_axis_tdata !== exp_head) n_mismatch++;
      end
    end
  end

  // ── output protocol monitor ──────────────────────────────────────────────
  // A beat offered and not taken must still be offered, unchanged, next cycle.
  logic                      held_v = 0;
  logic [DATA_WIDTH - 1 : 0] held_d;
  int                        n_proto = 0;
  always @(posedge m_clk) begin
    if (!m_rst_n) begin
      held_v <= 0;
    end else begin
      if (held_v && (!m_axis_tvalid || m_axis_tdata !== held_d)) n_proto++;
      held_v <= m_axis_tvalid && !m_axis_tready;
      held_d <= m_axis_tdata;
    end
  end

  // ── stimulus helpers ─────────────────────────────────────────────────────
  int seq = 0;
  function automatic logic [DATA_WIDTH - 1 : 0] next_record();
    logic [DATA_WIDTH - 1 : 0] r;
    for (int i = 0; i < DATA_WIDTH; i += 32) r[i +: 32] = $urandom;
    r[31 : 0] = seq;                       // a sequence number in the low word
    seq++;
    return r;
  endfunction

  // Offer one record and hold it until it is taken (write-side protocol).
  task automatic send_one(input logic [DATA_WIDTH - 1 : 0] r);
    @(posedge s_clk); #0.1;
    s_axis_tdata  = r;
    s_axis_tvalid = 1;
    do @(posedge s_clk); while (!s_axis_tready);
    #0.1;
    s_axis_tvalid = 0;
  endtask

  task automatic wait_drained(input int timeout_cycles);
    int t = 0;
    while ((expected.size() != 0 || m_axis_tvalid) && t < timeout_cycles) begin
      @(posedge m_clk); t++;
    end
  endtask

  task do_reset;
    s_rst_n = 0; m_rst_n = 0;
    repeat (4) @(posedge s_clk);
    repeat (4) @(posedge m_clk);
    #0.1; s_rst_n = 1; m_rst_n = 1;
    repeat (4) @(posedge s_clk);
  endtask

  // ── tests ────────────────────────────────────────────────────────────────
  bit stop_reader = 0;
  int accepted;
  int low_run;

  initial begin
    $display("\n================================================================");
    $display("  feature_buffer -- DATA_WIDTH=%0d DEPTH=%0d  s=%.2fns m=%.2fns",
             DATA_WIDTH, DEPTH, S_PERIOD, M_PERIOD);
    $display("================================================================");
    do_reset();

    // B1 ────────────────────────────────────────────────────────────────────
    $display("\n== B1: one record ==");
    m_axis_tready = 1;
    send_one(next_record());
    wait_drained(200);
    chk("B1: one in, one out", n_in == 1 && n_out == 1);
    chk("B1: unchanged", n_mismatch == 0 && n_unexpected == 0);

    // B2 ────────────────────────────────────────────────────────────────────
    $display("\n== B2: random traffic, %0d records ==", N_RANDOM);
    n_in = 0; n_out = 0;
    fork
      begin : writer
        for (int i = 0; i < N_RANDOM; i++) begin
          send_one(next_record());
          if ($urandom_range(0, 3) == 0) repeat ($urandom_range(1, 6)) @(posedge s_clk);
        end
      end
      begin : reader
        while (!stop_reader) begin
          @(posedge m_clk); #0.1;
          m_axis_tready = ($urandom_range(0, 2) != 0);
        end
      end
    join_any
    wait_drained(20 * N_RANDOM);
    stop_reader = 1;
    #20;
    m_axis_tready = 1;
    chk("B2: every record came out", n_out == N_RANDOM && n_in == N_RANDOM);
    chk("B2: in order and unmodified", n_mismatch == 0);
    chk("B2: nothing extra", n_unexpected == 0 && expected.size() == 0);
    chk("B2: output protocol held (tvalid/tdata stable until taken)", n_proto == 0);

    // B3 ────────────────────────────────────────────────────────────────────
    $display("\n== B3: consumer stalled -- fill, back-pressure, drain ==");
    @(posedge m_clk); #0.1; m_axis_tready = 0;
    repeat (8) @(posedge m_clk);
    s_stats_clear = 1; @(posedge s_clk); #0.1; s_stats_clear = 0;
    n_in = 0; n_out = 0;
    accepted = 0;
    // Offer continuously; count what is accepted until tready has stayed low
    // for long enough that the read side's pointer has been seen.
    begin
      low_run = 0;
      @(posedge s_clk); #0.1;
      s_axis_tdata = next_record(); s_axis_tvalid = 1;
      while (low_run < 40) begin
        @(posedge s_clk);
        if (s_axis_tready) begin
          accepted++; low_run = 0;
          #0.1; s_axis_tdata = next_record();
        end else begin
          low_run++;
        end
      end
      #0.1; s_axis_tvalid = 0;
      seq--;                               // the last offered record was never taken
    end
    $display("      accepted %0d before back-pressure (DEPTH=%0d)", accepted, DEPTH);
    chk("B3: holds DEPTH + 1 (RAM + output register)", accepted == DEPTH + 1);
    chk("B3: s_axis_tready low while full", s_axis_tready === 1'b0);
    chk("B3: occupancy reads DEPTH", s_occupancy == DEPTH);
    chk("B3: high watermark reads DEPTH", s_hiwater == DEPTH);
    chk("B3: stall cycles were counted", s_stall_cycles >= 30);
    chk("B3: output offered while stalled", m_axis_tvalid === 1'b1);
    @(posedge m_clk); #0.1; m_axis_tready = 1;
    wait_drained(10 * DEPTH + 100);
    chk("B3: all of them drained", n_out == accepted && expected.size() == 0);
    chk("B3: in order and unmodified", n_mismatch == 0 && n_unexpected == 0);
    repeat (8) @(posedge s_clk);
    chk("B3: occupancy back to 0", s_occupancy == 0);

    // B4 ────────────────────────────────────────────────────────────────────
    $display("\n== B4: stats clear ==");
    @(posedge s_clk); #0.1; s_stats_clear = 1;
    @(posedge s_clk); #0.1; s_stats_clear = 0;
    chk("B4: high watermark cleared", s_hiwater == 0);
    chk("B4: stall cycles cleared", s_stall_cycles == 0);

    $display("\n================================================================");
    $display("  Results: %0d passed, %0d failed  (total %0d)", pass_cnt, fail_cnt, pass_cnt + fail_cnt);
    $display("================================================================");
    if (fail_cnt == 0) $display("  ALL TESTS PASSED");
    else               $display("  SOME TESTS FAILED");
    $finish;
  end

  initial begin #5000000; $display("[TIMEOUT]"); $finish; end

endmodule
