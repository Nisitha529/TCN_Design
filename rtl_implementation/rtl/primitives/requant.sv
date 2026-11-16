`timescale 1ns/1ps

// requant -- turn a convolution's ACC_W-bit sum back into a DW-bit activation.
//
//   y = ReLU( saturate_DW( (acc >>> FRAC) + bias ) )        (ReLU only if RELU)
//
// Bit-exact with the end of IntModel.conv in qos_tcn/quant.py:
//   y = sat((acc >> FRAC_BITS) + b, I16);  y = max(y, 0) for conv1/conv2
// `>>>` is an arithmetic shift, i.e. floor division by 2^FRAC, exactly like
// numpy's >> on signed integers.
//
//   stage 1: s   = (acc >>> FRAC) + bias        one ACC_W+1-bit adder
//   stage 2: y   = clamp(s) then ReLU           two comparisons, no adder
//
// Why two stages: in the first synthesis of qos_tcn_engine (Artix-7) the
// slowest path was the whole of this done in one cycle straight after the
// multiply-accumulate -- 17 logic levels, 14 ns, ~69 MHz. Each stage here is a
// single short carry chain.
//
// Latency 2 cycles, one result per cycle. No reset on the data path (the
// valid bit qualifies it); `rst` clears only the valid pipeline.

module requant #(
  parameter ACC_W = 32,
  parameter DW    = 16,
  parameter FRAC  = 8,
  parameter RELU  = 1
)(
  input  wire                      clk,
  input  wire                      rst,          // synchronous, active high
  input  wire                      valid_in,
  input  wire signed [ACC_W - 1:0] acc,
  input  wire signed [DW - 1 : 0]  bias,
  output reg                       valid_out,
  output reg  signed [DW - 1 : 0]  y
);

  localparam signed [ACC_W : 0] YMAX =  (1 <<< (DW - 1)) - 1;
  localparam signed [ACC_W : 0] YMIN = -(1 <<< (DW - 1));

  // stage 1: shift and add the bias (one extra bit so the sum cannot wrap)
  reg signed [ACC_W : 0] s;
  reg                    v1;
  always_ff @(posedge clk) begin
    s  <= (acc >>> FRAC) + bias;
    v1 <= rst ? 1'b0 : valid_in;
  end

  // stage 2: saturate to DW bits, then ReLU
  always_ff @(posedge clk) begin
    if (s > YMAX)                 y <= YMAX[DW - 1 : 0];
    else if (s < YMIN)            y <= RELU ? '0 : YMIN[DW - 1 : 0];
    else if (RELU && s[ACC_W])    y <= '0;
    else                          y <= s[DW - 1 : 0];
    valid_out <= rst ? 1'b0 : v1;
  end

endmodule
