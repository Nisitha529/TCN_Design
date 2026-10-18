`timescale 1ns/1ps

// mac_lane -- one multiply-accumulate lane for the window engine.
//
//   valid_in, first, a, b  ──►  [ product_r = a*b ]  ──►  [ acc = first ? product : acc + product ]
//                               stage 1 (DSP M reg)      stage 2 (DSP P reg)
//
//   first = 1 starts a new sum: the accumulator LOADS the product instead of
//   adding it, so no separate clear cycle is needed between sums (mac_unit
//   needs one). Latency: acc reflects an input 2 cycles after it is presented;
//   valid_out marks that cycle.
//
// Why it is written this way -- each point measured with Vivado 2020.2,
// out-of-context synthesis on an Artix-7 (xc7a50t), 250 MHz clock:
//   mac_unit (1 stage, async reset)          1 DSP, 33 FF, 19 LUT, slack +0.50 ns
//   2 stages, async reset                    1 DSP, 66 FF, 53 LUT, slack +1.43 ns
//   2 stages, synchronous reset              1 DSP,  2 FF,  2 LUT, slack +2.34 ns
//   mac_lane (2 stages + load-or-accumulate) 1 DSP,  3 FF,  1 LUT, slack +0.91 ns
//     -> the whole lane is one DSP48: multiply, M register, and a P-register
//        accumulator whose input switches between 0 (load) and P (accumulate).
//        The extra cost of load-or-accumulate is that switch, driven from
//        first_r in fabric; it still closes 250 MHz with margin.
//
//   * product written as a*b into a 2*DW-bit wire. Sign-extending the inputs
//     first (as mac_unit does) gives the same result and also maps to one DSP;
//     this form just says what is meant.
//   * NO asynchronous reset on the data path. DSP48 registers only have
//     synchronous resets; an async reset keeps product_r, the accumulator and
//     the adder in fabric (66 FF + 53 LUT for a 2-stage MAC) instead of inside
//     the DSP (2 FF + 2 LUT). Data registers have no reset at all: `first`
//     loads the accumulator, so its value before the first sum never matters.
//   * no saturation in the accumulator: it would move the MAC out of the DSP,
//     and the golden model (qos_tcn/quant.py) asserts the ACC_W-bit sum never
//     overflows on real data. Saturation belongs in the rescale step after the
//     sum (requant), where 32 bits become 16.
//   * rst only clears the valid pipeline (synchronous).

module mac_lane #(
  parameter DW    = 16,
  parameter ACC_W = 32
)(
  input  wire                      clk,
  input  wire                      rst,        // synchronous, active high
  
  input  wire                      valid_in,   // a, b present a real tap this cycle
  input  wire                      first,      // first tap of a new sum
  
  input  wire signed [DW - 1 : 0]  a,
  input  wire signed [DW - 1 : 0]  b,
  
  output reg  signed [ACC_W - 1:0] acc,
  output reg                       valid_out   // acc updated from an input 2 cycles ago
);

  wire signed [2 * DW - 1 : 0] product = a * b;

  reg signed [2 * DW - 1 : 0] product_r;
  reg                         v1, first_r;
  wire signed [ACC_W - 1 : 0] product_ext = product_r;    // sign-extended

  // stage 1: product register (DSP M register); control bits reset synchronously
  always_ff @(posedge clk) begin
    product_r <= product;
    first_r   <= first;
    v1        <= rst ? 1'b0 : valid_in;
  end

  // stage 2: load-or-accumulate (DSP P register)
  always_ff @(posedge clk) begin
    if (v1) acc <= first_r ? product_ext : acc + product_ext;
    valid_out <= rst ? 1'b0 : v1;
  end

endmodule
