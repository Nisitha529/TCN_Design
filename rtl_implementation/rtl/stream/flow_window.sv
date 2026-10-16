`timescale 1ns/1ps

// flow_window -- collects each flow's first N packet records and hands the
// complete window to the TCN when the N-th one arrives.
//
//   feature_buffer ─► records ─► [ per-flow slot RAM ] ─► window ─► TCN input stage
//                                 2^FLOW_BITS rows x N slots
//
// This is the "keep the last W packets, recompute when classifying" option,
// with W = N: the TCN classifies a flow once, from its first N payload packets
// (the window the model is trained on, qos_tcn/train.py).
//
// Storage
//   slot RAM    one row per flow index, N slots of SLOT_W bits. A record is
//               written straight into slot pkt_idx with a per-slot write
//               enable -- no read-modify-write of the row.
//   valid RAM   one N-bit mask per flow index: which slots hold THIS flow's
//               packets. pkt_idx == 0 restarts it, so slots left over from an
//               earlier flow on the same index (a finished flow, or a hash
//               collision) are never mistaken for this one's.
//   A slot whose valid bit is clear goes out as zeros, which is exactly the
//   model's padding value (hw_encoding.encode_inputs): a record lost upstream
//   degrades to a missing packet, not to another flow's data.
//
// Timing
//   About 4 cycles per record (tready handshake, mask read, update), plus 3
//   to read out and present a window.
//   That is far above need: records arrive at (new flows/s) x N, e.g.
//   100k flows/s x 8 = 0.8M records/s against a 250 MHz clock. Taking a few
//   cycles per record means the valid-mask read-modify-write can never race
//   a second record for the same flow, so there is no forwarding logic.
//
// Flows that end early
//   A flow shorter than N would never reach the N-th packet and so never be
//   classified. ids.p4 marks a flow's end (TCP FIN/RST) with the record's `last`
//   bit: a last record that carries a packet (pkt_idx < N) is stored as usual
//   and then the window is flushed; a last record with no packet uses
//   pkt_idx = 31 and only flushes. A flushed window has a partial mask, and the
//   missing slots go out as zeros -- the padding the model was trained with for
//   short flows. A per-flow `emitted` bit stops a second window when a FIN
//   arrives after the flow already reached N, or a FIN is repeated.
//
// Records with pkt_idx >= N and no `last` are counted and ignored (ids.p4
// should not send them). Statistics are free-running counters.

module flow_window
  import qos_record_pkg::*;
#(
  parameter FLOW_BITS = 16,          // flow table rows = 2**FLOW_BITS (18 on the VU9P)
  parameter N         = 8,           // packets per window = classify at the N-th
  parameter RAM_STYLE = "block"      // "block" | "ultra"
)(
  input  wire                          clk,
  input  wire                          rst_n,

  // records, from feature_buffer's read side
  input  wire [REC_W - 1 : 0]          s_axis_tdata,
  input  wire                          s_axis_tvalid,
  output reg                           s_axis_tready,

  // completed windows, slot k = packet k (k = 0 first)
  output reg  [FLOW_BITS - 1 : 0]      m_flow_idx,
  output reg  [N * SLOT_W - 1 : 0]     m_window,
  output reg  [N - 1 : 0]              m_valid_mask,   // which slots were present
  output reg                           m_tvalid,
  input  wire                          m_tready,

  // statistics
  output reg  [31 : 0]                 st_records,
  output reg  [31 : 0]                 st_windows,
  output reg  [31 : 0]                 st_incomplete,  // windows with a missing slot
  output reg  [31 : 0]                 st_ignored,     // pkt_idx >= N, not last
  output reg  [31 : 0]                 st_flushed      // windows emitted early by `last`
);

  localparam DEPTH = 1 << FLOW_BITS;

  // ── memories ──────────────────────────────────────────────────────────────
  (* ram_style = RAM_STYLE *) reg [N * SLOT_W - 1 : 0] slot_mem  [0 : DEPTH - 1];
  // {emitted, mask[N-1:0]} per flow row
  (* ram_style = "block"   *) reg [N : 0]              valid_mem [0 : DEPTH - 1];

  // ── the record being processed ───────────────────────────────────────────
  reg [FLOW_BITS - 1 : 0] r_idx;
  reg [PKT_IDX_W - 1 : 0] r_pkt;
  reg [SLOT_W - 1 : 0]    r_slot;
  reg                     r_has;        // carries a packet (pkt_idx < N)
  reg                     r_last;       // flow ended
  reg                     r_flush;      // this window was emitted by `last`

  // ── control states ───────────────────────────────────────────────────────
  // The memory ports below are driven COMBINATIONALLY from the state, so a
  // read issued in state X has its data in the very next state. (Registered
  // enables put every read one cycle behind the state that used it.)
  typedef enum logic [2:0] {
    S_IDLE,      // take a record
    S_RDMASK,    // read this flow's valid mask
    S_UPDATE,    // mask is out: write the slot and the new mask
    S_READ,      // last slot written: read the whole row and the mask
    S_FORM,      // row is out: build the window
    S_OUT        // present it until taken
  } state_t;

  state_t state;

  // ── memory ports ─────────────────────────────────────────────────────────
  reg [N * SLOT_W - 1 : 0] slot_rdata;
  reg [N : 0]              valid_rdata;  // {emitted, mask}
  reg [N - 1 : 0]          new_mask;
  reg                      em_base;      // emitted bit before this record's decision
  reg                      emit;

  wire slot_we  = (state == S_UPDATE);
  wire slot_re  = (state == S_READ);
  wire valid_we = (state == S_UPDATE);
  wire valid_re = (state == S_RDMASK) || (state == S_READ);

  always_comb begin
    new_mask = valid_rdata[N - 1 : 0];
    em_base  = valid_rdata[N];
    if (r_has) begin
      if (r_pkt == 0) begin                  // a new flow on this row
        new_mask = '0;
        em_base  = 1'b0;
      end
      new_mask[r_pkt] = 1'b1;
    end
    emit = !em_base && ((r_has && r_pkt == N - 1) || (r_last && new_mask != '0));
  end

  // per-slot write enable: the shape that infers byte/word-write-enable RAM
  always_ff @(posedge clk) begin
    for (int k = 0; k < N; k++) begin
      if (slot_we && r_has && r_pkt == k) begin
        slot_mem[r_idx][k * SLOT_W +: SLOT_W] <= r_slot;
      end
    end
    if (slot_re) begin
      slot_rdata <= slot_mem[r_idx];
    end
  end

  always_ff @(posedge clk) begin
    if (valid_we) begin
      valid_mem[r_idx] <= {em_base | emit, new_mask};
    end
    if (valid_re) begin
      valid_rdata <= valid_mem[r_idx];
    end
  end

  // Simulation only: power-up contents are undefined in hardware, which is
  // harmless (a row is only read after pkt_idx 0 has restarted its mask), but
  // X in simulation would propagate into the mask on a flow's first record.
  // synthesis translate_off
  initial begin
    for (int i = 0; i < DEPTH; i++) valid_mem[i] = '0;
  end
  // synthesis translate_on

  // ── control ──────────────────────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state         <= S_IDLE;
      s_axis_tready <= 1'b0;
      m_tvalid      <= 1'b0;
      st_records    <= '0;
      st_windows    <= '0;
      st_incomplete <= '0;
      st_ignored    <= '0;
      st_flushed    <= '0;
    end else begin
      s_axis_tready <= 1'b0;

      case (state)
        S_IDLE: begin
          // tready is a registered one-cycle pulse: raised here, the
          // handshake completes on the NEXT edge if tvalid is still up, which
          // AXI-Stream guarantees once tvalid has been raised.
          if (s_axis_tvalid && !s_axis_tready) begin
            s_axis_tready <= 1'b1;
          end
          if (s_axis_tvalid && s_axis_tready) begin
            st_records <= st_records + 1'b1;
            if (rec_pkt_idx(s_axis_tdata) >= N && !rec_last(s_axis_tdata)) begin
              st_ignored <= st_ignored + 1'b1;
            end else begin
              r_has  <= rec_pkt_idx(s_axis_tdata) < N;
              r_last <= rec_last(s_axis_tdata);
              // low FLOW_BITS of flow_id (a part-select of a function result is not legal)
              r_idx <= s_axis_tdata[REC_W - FLOW_ID_W +: FLOW_BITS];
              r_pkt <= rec_pkt_idx(s_axis_tdata);
              r_slot <= rec_slot(s_axis_tdata);
              state <= S_RDMASK;
            end
          end
        end

        S_RDMASK: state <= S_UPDATE;            // valid_mem read on this edge

        S_UPDATE: begin
          // valid_rdata now holds the mask; slot and new mask written on this edge
          r_flush <= emit && !(r_has && r_pkt == N - 1);
          state   <= emit ? S_READ : S_IDLE;
        end

        S_READ: state <= S_FORM;                // row and mask read on this edge,
                                                // after S_UPDATE's writes landed

        S_FORM: begin
          for (int k = 0; k < N; k++) begin
            m_window[k * SLOT_W +: SLOT_W] <= valid_rdata[k] ? slot_rdata[k * SLOT_W +: SLOT_W] : '0;
          end
          m_valid_mask <= valid_rdata[N - 1 : 0];
          if (r_flush) st_flushed <= st_flushed + 1'b1;
          m_flow_idx   <= r_idx;
          m_tvalid     <= 1'b1;
          st_windows   <= st_windows + 1'b1;
          if (valid_rdata[N - 1 : 0] != {N{1'b1}}) begin
            st_incomplete <= st_incomplete + 1'b1;
          end
          state <= S_OUT;
        end

        S_OUT: begin
          if (m_tvalid && m_tready) begin
            m_tvalid <= 1'b0;
            state    <= S_IDLE;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
