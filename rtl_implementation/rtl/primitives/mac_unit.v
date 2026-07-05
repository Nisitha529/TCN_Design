module mac_unit #(
  parameter DATA_WIDTH = 16,
  parameter ACC_WIDTH  = 32   
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire                             clear,

  input  wire signed [DATA_WIDTH - 1 : 0] data_in,
  input  wire signed [DATA_WIDTH - 1 : 0] weight,

  output reg  signed [ACC_WIDTH - 1 : 0]  acc_out,
  output reg                              valid
);

  // Sign-extend operands to ACC_WIDTH before multiplying
  // Prevents truncation: 16-bit * 16-bit = 16-bit in Verilog without this
  wire signed [ACC_WIDTH-1:0] data_ext;
  wire signed [ACC_WIDTH-1:0] weight_ext;
  wire signed [ACC_WIDTH-1:0] product;

  assign data_ext   = $signed({{(ACC_WIDTH-DATA_WIDTH){data_in[DATA_WIDTH-1]}}, data_in});
  assign weight_ext = $signed({{(ACC_WIDTH-DATA_WIDTH){weight[DATA_WIDTH-1]}},  weight});
  assign product    = data_ext * weight_ext;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_out <= '0;
      valid   <= 1'b0;
    end else if (clear) begin
      acc_out <= '0;
      valid   <= 1'b0;
    end else if (en) begin
      acc_out <= acc_out + product;
      valid   <= 1'b1;
    end
  end

endmodule
