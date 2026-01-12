// -----------------------------------------------------------------------------
// 文件名: single_column_bank.v
// 描述: 单列累加器存储单元
// 架构: 使用 Distributed RAM (LUTRAM) 实现
//       - Read: Asynchronous (Combinational)
//       - Write: Synchronous (Clocked)
//       - RMW: 可以在单周期内完成 (Read -> Add -> Write)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module single_column_bank #(
    parameter BANK_ID = 0
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // --- Control Interface ---
    // addr: 同时用于读和写 (因为是单周期 RMW)
    // 假设输入数据 in_psum 对应的就是这个 addr 的位置
    input  wire [3:0]               addr,       // 深度 12，4-bit 足够
    input  wire                     wr_en,      // 写使能
    input  wire                     acc_mode,   // 0: Overwrite, 1: Accumulate

    // --- Data Interface ---
    input  wire [`ACC_WIDTH-1:0]    in_psum,    // 来自阵列的新数据
    output wire [`ACC_WIDTH-1:0]    out_acc     // 当前存储的值 (用于Debug或PPU)
);

    // -------------------------------------------------------------------------
    // Memory Declaration (Distributed RAM)
    // -------------------------------------------------------------------------
    // 深度为 ARRAY_ROW (12)，取 2 的幂次 16 方便寻址
    reg [`ACC_WIDTH-1:0] mem [0:15];

    // -------------------------------------------------------------------------
    // Asynchronous Read (LUTRAM 特性)
    // -------------------------------------------------------------------------
    // 直接组合逻辑读出旧值
    assign out_acc = mem[addr];

    // -------------------------------------------------------------------------
    // Accumulation Logic
    // -------------------------------------------------------------------------
    wire [`ACC_WIDTH-1:0] old_val;
    wire [`ACC_WIDTH-1:0] sum_val;
    wire [`ACC_WIDTH-1:0] write_val;

    assign old_val = out_acc;
    
    // 累加器: 如果是 ACC 模式，则加上旧值；否则直接覆盖
    // 注意: 这里是有符号加法
    assign sum_val = $signed(old_val) + $signed(in_psum);
    assign write_val = (acc_mode) ? sum_val : in_psum;

    // -------------------------------------------------------------------------
    // Synchronous Write
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en) begin
            mem[addr] <= write_val;
        end
    end
    
    // 初始化 (Optional, for simulation niceness)
    integer i;
    initial begin
        for (i=0; i<16; i=i+1) mem[i] = 0;
    end

endmodule