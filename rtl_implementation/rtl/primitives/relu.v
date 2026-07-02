module relu # (
  parameter DATA_WIDTH = 16
) (
  input  wire signed [DATA_WIDTH - 1 : 0] data_in,

  output wire signed [DATA_WIDTH - 1 : 0] data_out
);

  // Negative values are set to zero, positive values are passed through
  // Negative values can be detected by checking the sign bit (MSB) of the input data
  assign data_out = data_in[DATA_WIDTH - 1] ? {DATA_WIDTH{1'b0}} : data_in;

endmodule