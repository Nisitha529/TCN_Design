`timescale 1ns/1ps

// feature_buffer -- deep AXI4-Stream FIFO between the P4 pipeline's
// FeatureExport port and the TCN accelerator, crossing between their clocks.
//
//   p4rtl clock (s_*)                        TCN clock (m_*)
//   <app>_top.<feed>_t* ──► [ DEPTH-entry dual-clock RAM ] ──► TCN input
//
// Contract
//   * Records leave in arrival order, unmodified, exactly once. A single FIFO
//     is what keeps one flow's packets in order for a TCN that carries per-flow
//     state from one record to the next.
//   * This block never drops. When it is full it deasserts s_axis_tready, and
//     p4rtl's staging ring in front of it drops the NEWEST record and counts it
//     in the feed's `dropped` register (see <app>_cp_map.json). Every lost
//     record is therefore counted in exactly one place, which the host can
//     read; a second, independent drop point here would split that count.
//   * The packet path never waits on this block: p4rtl's staging ring is
//     the only thing s_axis_tready can hold back.
//
// Clock crossing
//   Gray-coded pointers through SYNC_STAGES flip-flops in each direction, the
//   usual dual-clock FIFO. Correct for unrelated clocks and also for one shared
//   clock (it then just costs a few cycles of latency). Both resets must be
//   asserted together; each is synchronised by its own domain's logic.
//   Timing: the Gray buses need a datapath-only max-delay of one destination
//   clock period -- see constraints/feature_buffer_cdc.xdc.
//
// Memory
//   Written on s_clk, read on m_clk through a REGISTERED read with an enable,
//   which is the shape that infers block RAM (or UltraRAM with
//   RAM_STYLE="ultra"). An asynchronous read would infer LUT RAM, which at
//   1024 x 128 bits is far too large. The registered read is turned back into
//   first-word-fall-through by fetching the next entry whenever the output
//   register is empty or being taken, so a full-rate consumer still gets one
//   record per cycle.
//
// Telemetry (write side, i.e. what the P4 side and its host see)
//   s_occupancy     entries held, as seen from the write side. Registered twice
//                   (Gray->binary, then the subtraction) to keep the telemetry
//                   off the critical path, so it lags by the synchroniser delay
//                   plus two cycles. It is a statistic only: the full flag
//                   compares the Gray pointers directly and does not lag.
//   s_hiwater       largest s_occupancy since reset / s_stats_clear
//   s_stall_cycles  cycles with s_axis_tvalid && !s_axis_tready: how often the
//                   TCN fell behind far enough to push back on p4rtl

module feature_buffer #(
  parameter DATA_WIDTH  = 128,       // = tdata_width in <app>_cp_map.json
  parameter ADDR_WIDTH  = 10,        // DEPTH = 2**ADDR_WIDTH entries
  parameter SYNC_STAGES = 2,         // >= 2
  parameter RAM_STYLE   = "block"    // "block" | "ultra" | "distributed"
)(
  // ── write side: p4rtl clock ──────────────────────────────────────────────
  input  wire                      s_clk,
  input  wire                      s_rst_n,

  input  wire [DATA_WIDTH - 1 : 0] s_axis_tdata,
  input  wire                      s_axis_tvalid,
  output wire                      s_axis_tready,

  input  wire                      s_stats_clear,   // one-cycle pulse
  output reg  [ADDR_WIDTH     : 0] s_occupancy,
  output reg  [ADDR_WIDTH     : 0] s_hiwater,
  output reg  [31 : 0]             s_stall_cycles,

  // ── read side: TCN clock ─────────────────────────────────────────────────
  input  wire                      m_clk,
  input  wire                      m_rst_n,

  output reg  [DATA_WIDTH - 1 : 0] m_axis_tdata,
  output reg                       m_axis_tvalid,
  input  wire                      m_axis_tready
);

  localparam DEPTH = 1 << ADDR_WIDTH;
  localparam PTR_W = ADDR_WIDTH + 1;     // one wrap bit above the address

  // ── helpers ──────────────────────────────────────────────────────────────
  function automatic [PTR_W - 1 : 0] bin2gray(input [PTR_W - 1 : 0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic [PTR_W - 1 : 0] gray2bin(input [PTR_W - 1 : 0] g);
    gray2bin[PTR_W - 1] = g[PTR_W - 1];
    for (int i = PTR_W - 2; i >= 0; i--) begin
      gray2bin[i] = gray2bin[i + 1] ^ g[i];
    end
  endfunction

  // ── storage ──────────────────────────────────────────────────────────────
  (* ram_style = RAM_STYLE *)
  reg [DATA_WIDTH - 1 : 0] mem [0 : DEPTH - 1];

  // All four pointers declared up front: each side's synchroniser reads the
  // OTHER side's Gray pointer, and a use before the declaration becomes an
  // implicit 1-bit net in iverilog (an X that never resolves) and an error in
  // xvlog.
  reg  [PTR_W - 1 : 0] wr_bin;
  reg  [PTR_W - 1 : 0] wr_gray;
  reg  [PTR_W - 1 : 0] rd_bin;
  reg  [PTR_W - 1 : 0] rd_gray;

  // ── write side ───────────────────────────────────────────────────────────
  // read pointer, Gray, synchronised into s_clk
  (* ASYNC_REG = "TRUE" *) reg [SYNC_STAGES - 1 : 0][PTR_W - 1 : 0] rd_gray_sync;
  wire [PTR_W - 1 : 0] rd_gray_s = rd_gray_sync[SYNC_STAGES - 1];

  // Full: the write pointer is exactly one lap ahead of the read pointer.
  // In Gray code that is "top two bits inverted, the rest equal".
  wire full = (wr_gray == {~rd_gray_s[PTR_W - 1 : PTR_W - 2], rd_gray_s[PTR_W - 3 : 0]});
  wire wr_en = s_axis_tvalid && !full;

  assign s_axis_tready = !full;

  // Telemetry pipeline. In one cycle (Gray->binary, subtract, compare with the
  // watermark) this was the slowest path in the block: -1.55 ns at 250 MHz on
  // an Artix-7, against +2.1 ns for the real data path.
  reg [PTR_W - 1 : 0] rd_bin_s;

  always_ff @(posedge s_clk) begin
    if (wr_en) begin
      mem[wr_bin[ADDR_WIDTH - 1 : 0]] <= s_axis_tdata;
    end
  end

  always_ff @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      wr_bin  <= '0;
      wr_gray <= '0;
    end else if (wr_en) begin
      wr_bin  <= wr_bin + 1'b1;
      wr_gray <= bin2gray(wr_bin + 1'b1);
    end
  end

  always_ff @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      rd_gray_sync <= '0;
    end else begin
      rd_gray_sync <= {rd_gray_sync[SYNC_STAGES - 2 : 0], rd_gray};
    end
  end

  always_ff @(posedge s_clk or negedge s_rst_n) begin
    if (!s_rst_n) begin
      rd_bin_s       <= '0;
      s_occupancy    <= '0;
      s_hiwater      <= '0;
      s_stall_cycles <= '0;
    end else begin
      rd_bin_s    <= gray2bin(rd_gray_s);
      s_occupancy <= wr_bin - rd_bin_s;
      if (s_stats_clear) begin
        s_hiwater      <= '0;
        s_stall_cycles <= '0;
      end else begin
        if (s_occupancy > s_hiwater) begin
          s_hiwater <= s_occupancy;
        end
        if (s_axis_tvalid && !s_axis_tready) begin
          s_stall_cycles <= s_stall_cycles + 1'b1;
        end
      end
    end
  end

  // ── read side ────────────────────────────────────────────────────────────
  // write pointer, Gray, synchronised into m_clk (a packed shift register:
  // iverilog does not re-evaluate a continuous assign from an UNPACKED array
  // element written in a loop, so the last stage read back as X)
  (* ASYNC_REG = "TRUE" *) reg [SYNC_STAGES - 1 : 0][PTR_W - 1 : 0] wr_gray_sync;
  wire [PTR_W - 1 : 0] wr_gray_m = wr_gray_sync[SYNC_STAGES - 1];

  wire empty = (rd_gray == wr_gray_m);

  // Fetch the next entry into the output register when there is one and the
  // register is free or is being taken this cycle. This is what makes a
  // registered (block-RAM) read look first-word-fall-through to the consumer.
  wire rd_en = !empty && (!m_axis_tvalid || m_axis_tready);

  // No reset on the wide data register: a reset there stops the read
  // register being absorbed into the RAM. m_axis_tvalid gates it.
  always_ff @(posedge m_clk) begin
    if (rd_en) begin
      m_axis_tdata <= mem[rd_bin[ADDR_WIDTH - 1 : 0]];
    end
  end

  always_ff @(posedge m_clk or negedge m_rst_n) begin
    if (!m_rst_n) begin
      rd_bin        <= '0;
      rd_gray       <= '0;
      m_axis_tvalid <= 1'b0;
    end else begin
      if (rd_en) begin
        rd_bin  <= rd_bin + 1'b1;
        rd_gray <= bin2gray(rd_bin + 1'b1);
      end
      if (rd_en) begin
        m_axis_tvalid <= 1'b1;
      end else if (m_axis_tready) begin
        m_axis_tvalid <= 1'b0;
      end
    end
  end

  always_ff @(posedge m_clk or negedge m_rst_n) begin
    if (!m_rst_n) begin
      wr_gray_sync <= '0;
    end else begin
      wr_gray_sync <= {wr_gray_sync[SYNC_STAGES - 2 : 0], wr_gray};
    end
  end

  // ── parameter checks ─────────────────────────────────────────────────────
  initial begin
    if (ADDR_WIDTH < 2) begin
      $error("feature_buffer: ADDR_WIDTH must be >= 2 (the full test uses the top two pointer bits)");
    end
    if (SYNC_STAGES < 2) begin
      $error("feature_buffer: SYNC_STAGES must be >= 2");
    end
  end

endmodule
