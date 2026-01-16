// -----------------------------------------------------------------------------
// 文件名: src/accumulator_bank.v
// 版本: 2.0 (Parameter Propagation)
// 描述: 累加器组顶层，管理 16 列 Bank
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module accumulator_bank #(
    parameter ADDR_WIDTH = 8 // Default to 8 to match sub-modules
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Unified Control ---
    input  wire [ADDR_WIDTH-1:0]        addr,    // Shared address for all cols
    input  wire                         wr_en,   // Shared write enable
    input  wire                         acc_mode,// Shared mode

    // --- Parallel Data ---
    // Input: 16 cols * 32 bits
    input  wire [`ARRAY_COL*`ACC_WIDTH-1:0] in_psum_vec,
    // Output: 16 cols * 32 bits
    output wire [`ARRAY_COL*`ACC_WIDTH-1:0] out_acc_vec
);

    genvar c;
    generate
        for (c = 0; c < `ARRAY_COL; c = c + 1) begin : COL_BANK
            
            // Slice input/output vectors
            wire [`ACC_WIDTH-1:0] col_in;
            wire [`ACC_WIDTH-1:0] col_out;

            assign col_in = in_psum_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH];
            assign out_acc_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH] = col_out;

            // Instantiate Bank with Parameter
            single_column_bank #(
                .BANK_ID(c),
                .DEPTH_LOG2(ADDR_WIDTH) // Pass down the width
            ) u_bank (
                .clk      (clk),
                .rst_n    (rst_n),
                .addr     (addr),
                .wr_en    (wr_en),
                .acc_mode (acc_mode),
                .in_psum  (col_in),
                .out_acc  (col_out)
            );
        end
    endgenerate

endmodule