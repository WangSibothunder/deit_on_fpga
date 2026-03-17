// -----------------------------------------------------------------------------
// 文件: src/rtl/single_column_bank.v
// 说明: 单列累加器存储（RMW + 写穿透）
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 规格书索引
// 模块: single_column_bank
// 规格书: docs/single_column_bank.md
// 用途: 单列累加器存储 (RMW)，支持覆盖/累加两种模式
// 关键参数: DEPTH_LOG2(深度), BANK_ID(标识)
// 接口分组:
//   - Control: addr/wr_en/acc_mode
//   - Data: in_psum/out_acc
// 时序要点:
//   - 组合读旧值 + 组合加法，写同步；写穿透输出
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
    // 2. Read-Modify-Write Logic
    // -------------------------------------------------------------------------
    
    // Step A: Read Old Value (Asynchronous read)
    wire signed [`ACC_WIDTH-1:0] old_val = mem[addr];

    // Step B: Calculate New Value
    reg signed [`ACC_WIDTH-1:0] next_val;
    
    always @(*) begin
        if (acc_mode) begin
            // Accumulate Mode: Old + New
            next_val = old_val + in_psum;
        end else begin
            // Overwrite Mode: New only (First Tile)
            next_val = in_psum;
        end
    end

    // Step C: Write Back (Synchronous)
    always @(posedge clk) begin
        if (wr_en) begin
            mem[addr] <= next_val;
        end
    end

    // -------------------------------------------------------------------------
    // 3. Output Logic with Bypass (CRITICAL FIX)
    // -------------------------------------------------------------------------
    // Old Logic: assign out_acc = mem[addr]; 
    // Bug: When wr_en is high, mem[addr] is OLD value until next clock. 
    // PPU captures OLD value.
    
    // New Logic: Write-Through / Bypass
    // If writing, output the calculated 'next_val' immediately.
    // If reading (idle), output 'mem[addr]'.
    
    assign out_acc = (wr_en) ? next_val : old_val;

    // Init for simulation
    integer i;
    initial begin
        for (i=0; i<(1<<DEPTH_LOG2); i=i+1) mem[i] = 0;
    end

endmodule
