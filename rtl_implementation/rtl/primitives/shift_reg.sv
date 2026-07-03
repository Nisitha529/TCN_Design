module shift_reg # (
  parameter DATA_WIDTH  = 16,
  parameter DEPTH       = 4
)(
  input  wire                             clk,
  input  wire                             rst_n,

  input  wire                             en,
  input  wire signed [DATA_WIDTH - 1 : 0] data_in,

  output wire signed [DATA_WIDTH - 1 : 0] taps [0 : DEPTH]
);
  reg signed [DATA_WIDTH - 1 : 0] delay [0 : DEPTH - 1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < DEPTH; i++) begin
        delay [i]  <= '0;
      end 
    end else begin
      if (en) begin
        delay [0]  <= data_in;

        for (int i = 1; i < DEPTH; i++) begin
          delay[i] <= delay[i - 1];
        end

      end
    end
  end

  assign taps [0] = data_in;

  generate
    for (genvar i = 1; i <= DEPTH; i++) begin
      assign taps [i] = delay [i - 1];
    end
  endgenerate

endmodule