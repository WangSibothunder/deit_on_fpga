// -----------------------------------------------------------------------------
// 文件: src/rtl/accumulator_bank.v
// 说明: 累加器 Bank 顶层，管理 16 列累加存储
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 规格书索引
// 模块: accumulator_bank
// 规格书: docs/accumulator_bank.md
// 用途: 16 列累加器 Bank 顶层，统一地址/写使能控制
// 关键参数: ADDR_WIDTH(地址位宽，默认 8 -> 深度 256)
// 接口分组:
//   - Control: addr/wr_en/acc_mode
//   - Data: in_psum_vec / out_acc_vec (16 列并行)
// 时序要点:
//   - 每列单独 RMW，写穿透输出，写当拍即更新
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
            // BANK_ID 仅用于调试/识别，不影响功能
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
