`timescale 1ns/1ps

// syn_flow_window_wrap -- a synthesis harness for flow_window (same idea as
// syn_engine_wrap): records come from a free-running LFSR, and every output is
// XOR-reduced into one registered pin. flow_window has ~500 data ports, more
// than the Cyclone IV has pins.
//
// Not for simulation; behaviour is tested by tb/stream/tb_flow_window.sv.

module syn_flow_window_wrap
  import qos_record_pkg::*;
#(
  parameter FLOW_BITS = 12,
  parameter N         = 8
)(
  input  wire clk,
  input  wire rst_n,
  output reg  obs
);

  reg [63:0] lfsr;
  always_ff @(posedge clk) begin
    if (!rst_n) lfsr <= 64'h1357_9BDF_2468_ACE0;
    else        lfsr <= {lfsr[62:0], lfsr[63] ^ lfsr[62] ^ lfsr[60] ^ lfsr[59]};
  end

  wire [FLOW_BITS - 1 : 0]  m_flow_idx;
  wire [N * SLOT_W - 1 : 0] m_window;
  wire [N - 1 : 0]          m_valid_mask;
  wire                      m_tvalid, s_tready;
  wire [31:0]               st_records, st_windows, st_incomplete, st_ignored, st_flushed;

  flow_window #(.FLOW_BITS(FLOW_BITS), .N(N)) fw (
    .clk(clk), .rst_n(rst_n),
    .s_axis_tdata(lfsr), .s_axis_tvalid(lfsr[7]), .s_axis_tready(s_tready),
    .m_flow_idx(m_flow_idx), .m_window(m_window), .m_valid_mask(m_valid_mask),
    .m_tvalid(m_tvalid), .m_tready(lfsr[13]),
    .st_records(st_records), .st_windows(st_windows), .st_incomplete(st_incomplete),
    .st_ignored(st_ignored), .st_flushed(st_flushed)
  );

  always_ff @(posedge clk) begin
    obs <= ^{m_flow_idx, m_window, m_valid_mask, m_tvalid, s_tready,
             st_records, st_windows, st_incomplete, st_ignored, st_flushed};
  end

endmodule
