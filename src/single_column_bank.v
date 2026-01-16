// -----------------------------------------------------------------------------
// 文件名: src/single_column_bank.v
// 版本: 2.0 (Parameterize Depth)
// 描述: 单列累加器存储单元 (LUTRAM / BRAM)
//       - 升级: 支持 DEPTH_LOG2 参数配置，默认为 8 (Depth 256) 以支持 ViT 序列长度
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module single_column_bank #(
    parameter BANK_ID    = 0,
    parameter DEPTH_LOG2 = 8  // 2^8 = 256 > 197 (DeiT Sequence Length)
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // --- Control Interface ---
    input  wire [DEPTH_LOG2-1:0]    addr,       // Width parameterised
    input  wire                     wr_en,
    input  wire                     acc_mode,   // 0: Overwrite, 1: Accumulate

    // --- Data Interface ---
    input  wire [`ACC_WIDTH-1:0]    in_psum,    // Partial Sum in
    output wire [`ACC_WIDTH-1:0]    out_acc     // Accumulator out
);

    // -------------------------------------------------------------------------
    // Memory Declaration
    // -------------------------------------------------------------------------
    // Depth = 2^DEPTH_LOG2
    // Vivado 可能会根据深度自动选择使用 Distributed RAM (LUT) 还是 Block RAM (BRAM)
    // 对于 Depth=256, Width=32, 总共 8Kb。通常还是会用 LUTRAM，或者 0.5 个 BRAM。
    (* ram_style = "distributed" *) 
    reg [`ACC_WIDTH-1:0] mem [0:(1<<DEPTH_LOG2)-1];

    // -------------------------------------------------------------------------
    // Asynchronous Read (组合逻辑读)
    // -------------------------------------------------------------------------
    assign out_acc = mem[addr];

    // -------------------------------------------------------------------------
    // Accumulate / Overwrite Logic
    // -------------------------------------------------------------------------
    wire [`ACC_WIDTH-1:0] old_val;
    wire [`ACC_WIDTH-1:0] sum_val;
    wire [`ACC_WIDTH-1:0] write_val;

    assign old_val = out_acc;
    
    // Signed Addition
    assign sum_val = $signed(old_val) + $signed(in_psum);
    
    // Mux for mode
    assign write_val = (acc_mode) ? sum_val : in_psum;

    // -------------------------------------------------------------------------
    // Synchronous Write
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en) begin
            mem[addr] <= write_val;
        end
    end

    // Init for simulation
    integer i;
    initial begin
        for (i=0; i<(1<<DEPTH_LOG2); i=i+1) mem[i] = 0;
    end

endmodule