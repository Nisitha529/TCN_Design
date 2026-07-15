`timescale 1ns/1ps

module shift_reg #(
  parameter DATA_WIDTH = 16,
  parameter DEPTH      = 4
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire signed [DATA_WIDTH - 1 : 0] data_in,

  // flat packed: tap k occupies bits [k*DATA_WIDTH +: DATA_WIDTH]
  // tap 0 = data_in (current sample), tap k = input from k*en cycles ago
  output wire [(DEPTH + 1) * DATA_WIDTH - 1 : 0] taps
);

  reg signed [DATA_WIDTH - 1 : 0] delay [0 : DEPTH - 1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        delay[i] <= '0;
      end
    end else if (en) begin
      delay[0] <= data_in;
      for (int i = 1; i < DEPTH; i++) begin
        delay[i] <= delay[i - 1];
      end
    end
  end

  // tap 0: current input
  assign taps[0 * DATA_WIDTH +: DATA_WIDTH] = data_in;

  generate
    for (genvar i = 1; i <= DEPTH; i++) begin : gen_taps
      assign taps[i * DATA_WIDTH +: DATA_WIDTH] = delay[i - 1];
    end
  endgenerate

endmodule
