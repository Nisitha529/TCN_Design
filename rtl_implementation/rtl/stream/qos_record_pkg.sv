`timescale 1ns/1ps

// qos_record_pkg -- the 64-bit FeatureExport record and the per-packet slot.
//
// Mirrors qos_tcn/hw_encoding.py (REC_FIELDS, pack_slot). ids.p4 builds the
// record high bits first:
//   push(flow_id ++ pkt_idx ++ size ++ dir ++ ipt_u ++ push ++ last ++ 9w0)
//
//   [63:44] flow_id   index into the per-flow tables (hash of the flow key)
//   [43:39] pkt_idx   payload-packet number within the flow, 0 = first
//   [38:28] size      transport payload bytes
//   [27]    dir       1 = same direction as the flow's first packet
//   [26:11] ipt_u     inter-packet time, 2^18 cycles @ 250 MHz (1.048576 ms)
//   [10]    push      TCP PSH
//   [9]     last      flow ended (TCP FIN/RST): flush the window now. With
//                     pkt_idx = 31 the record carries no packet, only the flush.
//   [8:0]   0
//
// A slot is what flow_window stores per packet: {3'b0, size, dir, ipt_u, push}.

package qos_record_pkg;

  localparam int REC_W     = 64;
  localparam int FLOW_ID_W = 20;
  localparam int PKT_IDX_W = 5;
  localparam int SIZE_W    = 11;
  localparam int IPT_W     = 16;
  localparam int SLOT_W    = 32;

  function automatic logic [FLOW_ID_W - 1 : 0] rec_flow_id(input logic [REC_W - 1 : 0] r);
    return r[63 : 44];
  endfunction

  function automatic logic [PKT_IDX_W - 1 : 0] rec_pkt_idx(input logic [REC_W - 1 : 0] r);
    return r[43 : 39];
  endfunction

  function automatic logic rec_last(input logic [REC_W - 1 : 0] r);
    return r[9];
  endfunction

  // {3'b0, size[10:0], dir, ipt_u[15:0], push} -- the record's [38:10]
  function automatic logic [SLOT_W - 1 : 0] rec_slot(input logic [REC_W - 1 : 0] r);
    return {3'b000, r[38 : 10]};
  endfunction

endpackage
