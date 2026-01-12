// -----------------------------------------------------------------------------
// 文件名: accumulator_bank.v
// 描述: 顶层累加器堆，包含 16 个独立的 Bank
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module accumulator_bank (
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Global Control ---
    input  wire [3:0]                   addr,       // 广播给所有 Bank
    input  wire                         wr_en,      // 广播给所有 Bank
    input  wire                         acc_mode,   // 广播给所有 Bank

    // --- Data Path ---
    // Input: 来自 Systolic Array 的 16列并行数据
    input  wire [`ARRAY_COL*`ACC_WIDTH-1:0] in_psum_vec,
    
    // Output: 16列累加器的当前值
    output wire [`ARRAY_COL*`ACC_WIDTH-1:0] out_acc_vec
);

    genvar c;
    generate
        for (c = 0; c < `ARRAY_COL; c = c + 1) begin : COL_BANK
            
            // 拆包 Input Vector
            wire [`ACC_WIDTH-1:0] bank_in;
            assign bank_in = in_psum_vec[(c * `ACC_WIDTH) +: `ACC_WIDTH];

            // 打包 Output Vector
            wire [`ACC_WIDTH-1:0] bank_out;
            assign out_acc_vec[(c * `ACC_WIDTH) +: `ACC_WIDTH] = bank_out;

            // 实例化 Single Bank
            single_column_bank #(
                .BANK_ID(c)
            ) bank_inst (
                .clk        (clk),
                .rst_n      (rst_n),
                .addr       (addr),
                .wr_en      (wr_en),
                .acc_mode   (acc_mode),
                .in_psum    (bank_in),
                .out_acc    (bank_out)
            );
            
        end
    endgenerate

endmodule