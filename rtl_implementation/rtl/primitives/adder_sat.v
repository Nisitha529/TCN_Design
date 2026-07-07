module adder_sat # (
  parameter DATA_WIDTH = 32
)(
  input  wire signed [DATA_WIDTH - 1 : 0] a,
  input  wire signed [DATA_WIDTH - 1 : 0] b,

  output wire signed [DATA_WIDTH - 1 : 0] result
);

  wire signed [DATA_WIDTH : 0] sum; // One extra bit for overflow detection

  assign sum = $signed({a[DATA_WIDTH-1], a}) + $signed({b[DATA_WIDTH-1], b});

  assign result = (sum[DATA_WIDTH] != sum[DATA_WIDTH-1]) ? 
                                                           (sum[DATA_WIDTH] ? 
                                                                              $signed({1'b1, {(DATA_WIDTH-1){1'b0}}})   // underflow → MIN
                                                                            : $signed({1'b0, {(DATA_WIDTH-1){1'b1}}}))  // overflow  → MAX
                 
                                                         : $signed(sum[DATA_WIDTH-1:0]);                                // no overflow

endmodule 
