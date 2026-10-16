`timescale 1ns/1ps

// qos_input_stage -- packet slots -> lookup-table outputs, the TCN's input
// channels. Bit-exact with IntModel.lookup (qos_tcn/quant.py) applied to
// hw_encoding.encode_inputs.
//
// Per slot {size[10:0], dir, ipt_u[15:0], push} (flow_window's layout) and its
// valid bit:
//   size_bin = size >> 3                        0..255
//   ipt_bin  = 4*e + f, where v = ipt_u + 1, e = index of v's leading one,
//              f = the two bits just below it   0..67   (log2 in quarter steps)
//   dir_bin  = 2 forward / 1 reverse
//   push_bin = push
// and every bin is 0 for an invalid (padding) slot, which is what the model
// sees for positions past the end of a short flow.
//
// Each bin indexes a small table of learned Q8.8 vectors; their concatenation
// [size | ipt | dir | push] is the position's ES+EI+ED+EP input channels.
// One position per cycle: N + 1 cycles from start to done.

module qos_input_stage #(
  parameter N      = 8,
  parameter ES     = 8,
  parameter EI     = 4,
  parameter ED     = 2,
  parameter EP     = 1,
  parameter DW     = 16,
  parameter SLOT_W = 32,
  parameter SIZE_FILE = "emb_size.hex",
  parameter IPT_FILE  = "emb_ipt.hex",
  parameter DIR_FILE  = "emb_dir.hex",
  parameter PUSH_FILE = "emb_push.hex"
)(
  input  wire                         clk,
  input  wire                         rst_n,
  input  wire                         start,
  input  wire [N * SLOT_W - 1 : 0]    slots,
  input  wire [N - 1 : 0]             mask,
  output reg  [N * (ES + EI + ED + EP) * DW - 1 : 0] act,
  output reg                          done
);

  localparam C0 = ES + EI + ED + EP;
  localparam TW = $clog2(N + 1);

  reg [ES * DW - 1 : 0] size_tab [0 : 255];
  reg [EI * DW - 1 : 0] ipt_tab  [0 : 67];
  reg [ED * DW - 1 : 0] dir_tab  [0 : 2];
  reg [EP * DW - 1 : 0] push_tab [0 : 1];
  initial begin
    $readmemh(SIZE_FILE, size_tab);
    $readmemh(IPT_FILE,  ipt_tab);
    $readmemh(DIR_FILE,  dir_tab);
    $readmemh(PUSH_FILE, push_tab);
  end

  reg            run, r_v;
  reg [TW - 1:0] t, r_t;
  reg [ES * DW - 1 : 0] r_size;
  reg [EI * DW - 1 : 0] r_ipt;
  reg [ED * DW - 1 : 0] r_dir;
  reg [EP * DW - 1 : 0] r_push;

  // ── bins for position t ──────────────────────────────────────────────────
  wire [SLOT_W - 1 : 0] s     = slots[t * SLOT_W +: SLOT_W];
  wire                  valid = mask[t];
  wire [10 : 0]         size  = s[28 : 18];
  wire                  dirb  = s[17];
  wire [15 : 0]         ipt_u = s[16 : 1];
  wire                  push  = s[0];

  wire [16 : 0] v = {1'b0, ipt_u} + 17'd1;
  reg  [4 : 0]  e;
  always_comb begin
    e = '0;
    for (int b = 1; b < 17; b++) if (v >= (17'd1 << b)) e = b[4:0];
  end
  wire [18 : 0] v4      = {v, 2'b00} >> e;
  wire [6 : 0]  ipt_bin = valid ? {e, 2'b00} + v4[1 : 0] : '0;
  wire [7 : 0]  size_bin = valid ? size[10 : 3] : '0;
  wire [1 : 0]  dir_bin  = valid ? (dirb ? 2'd2 : 2'd1) : 2'd0;
  wire          push_bin = valid & push;

  // ── one position per cycle: registered table reads, then write act ──────
  always_ff @(posedge clk) begin
    r_size <= size_tab[size_bin];
    r_ipt  <= ipt_tab[ipt_bin];
    r_dir  <= dir_tab[dir_bin];
    r_push <= push_tab[push_bin];
    r_t    <= t;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; r_v <= 1'b0; done <= 1'b0; t <= '0;
    end else begin
      done <= 1'b0;
      r_v  <= run;
      if (start && !run && !r_v) begin
        run <= 1'b1; t <= '0;
      end else if (run) begin
        if (t == N - 1) run <= 1'b0;
        else            t <= t + 1'b1;
      end
      if (r_v) begin
        act[r_t * C0 * DW +: C0 * DW] <= {r_push, r_dir, r_ipt, r_size};   // channel 0 = size dim 0
        if (r_t == N - 1) done <= 1'b1;
      end
    end
  end

endmodule
