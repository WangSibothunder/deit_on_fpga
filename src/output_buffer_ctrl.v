// -----------------------------------------------------------------------------
// 文件名: src/output_buffer_ctrl.v
// 描述: 输出缓冲控制器 (FIFO + Gearbox)
//       - 功能 1: 缓冲 PPU 的突发输出 (128-bit)，解耦计算与传输时序
//       - 功能 2: Gearbox 协议转换 (128-bit -> 2x 64-bit AXI-Stream)
//       - 深度: 默认 256，足以容纳 DeiT-Tiny 的最大 M=197，防止反压导致数据丢失
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module output_buffer_ctrl #(
    // 深度设为 256，覆盖 M=197 的最大情况
    parameter DEPTH_LOG2 = 8  
)(
    input  wire          clk,
    input  wire          rst_n,

    // --- PPU Interface (Write Side) ---
    // PPU 计算出的 128-bit 宽数据 (16 x INT8)
    input  wire [127:0]  i_data,
    input  wire          i_valid,
    
    // (可选) Full 信号，但在设计上我们保证 FIFO 够大，
    // 如果真的满了，说明 AXI 彻底死锁了，丢失数据在所难免。
    output wire          o_full,

    // --- AXI-Stream Interface (Read Side) ---
    // 输出给 DMA 的 64-bit 宽数据
    output reg  [63:0]   axis_tdata,
    output reg           axis_tvalid,
    input  wire          axis_tready,
    output reg           axis_tlast
);

    // -------------------------------------------------------------------------
    // 1. Synchronous FIFO (Width=128, Depth=256)
    // -------------------------------------------------------------------------
    localparam DEPTH = 1 << DEPTH_LOG2;
    
    reg [127:0] mem [0:DEPTH-1];
    reg [DEPTH_LOG2:0] wr_ptr; // 多一位用于判断 Full/Empty
    reg [DEPTH_LOG2:0] rd_ptr;
    
    wire empty = (wr_ptr == rd_ptr);
    wire full  = (wr_ptr[DEPTH_LOG2] != rd_ptr[DEPTH_LOG2]) && 
                 (wr_ptr[DEPTH_LOG2-1:0] == rd_ptr[DEPTH_LOG2-1:0]);
    
    assign o_full = full;

    // --- Write Logic ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else begin
            if (i_valid && !full) begin
                mem[wr_ptr[DEPTH_LOG2-1:0]] <= i_data;
                wr_ptr <= wr_ptr + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Read Logic & Gearbox FSM (128 -> 64)
    // -------------------------------------------------------------------------
    // 这里的 FSM 负责从 FIFO 读取 128-bit，并分两次 (Low 64, High 64) 发送
    
    localparam S_IDLE      = 0;
    localparam S_FETCH     = 1; // 读 FIFO 等待 RAM 输出
    localparam S_SEND_LOW  = 2; // 发送低 64 位
    localparam S_SEND_HIGH = 3; // 发送高 64 位
    
    reg [1:0]   state;
    reg [127:0] data_cache;     // 锁存从 FIFO 读出的数据
    
    // FIFO Read Enable
    reg fifo_re;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
            state <= S_IDLE;
            fifo_re <= 0;
            axis_tvalid <= 0;
            axis_tdata <= 0;
            axis_tlast <= 0; // TLAST 逻辑通常由 DMA 控制长度，这里常置 0 或在最后一次拉高
            data_cache <= 0;
        end else begin
            // 默认信号
            fifo_re <= 0;
            
            case (state)
                S_IDLE: begin
                    axis_tvalid <= 0;
                    if (!empty) begin
                        // FIFO 非空，发起读取
                        fifo_re <= 1;
                        rd_ptr <= rd_ptr + 1;
                        state <= S_FETCH;
                    end
                end

                S_FETCH: begin
                    // 等待 RAM 数据读出 (假设同步 RAM Read Latency = 1)
                    // 在这个周期，数据到达 mem output，我们需要锁存它
                    // 注意：如果是分布式 RAM (Distributed RAM)，数据可能立即可用；
                    // 如果是 BRAM，通常需要这一拍等待。为了稳健，我们假设需要这一拍。
                    
                    // 实际上，如果上面 rd_ptr 变了，mem[...] 在这一拍结束时有效
                    // 我们可以在下一拍使用 mem[rd_ptr-1]。
                    // 这里简化逻辑：直接在 Fetch 状态锁存
                    data_cache <= mem[rd_ptr[DEPTH_LOG2-1:0] - 1]; 
                    
                    // 准备发送 Low
                    // 这里利用 Non-blocking 特性，data_cache 更新在下一拍
                    // 所以我们直接用组合逻辑引用 mem 或者多等一拍
                    // 为了时序安全，我们多等一拍进入 SEND_LOW
                    state <= S_SEND_LOW;
                end

                S_SEND_LOW: begin
                    // 发送低 64 位
                    axis_tdata  <= data_cache[63:0];
                    axis_tvalid <= 1;
                    
                    if (axis_tready) begin
                        // 握手成功，准备发高位
                        state <= S_SEND_HIGH;
                    end
                end

                S_SEND_HIGH: begin
                    // 发送高 64 位
                    axis_tdata  <= data_cache[127:64];
                    axis_tvalid <= 1;
                    
                    if (axis_tready) begin
                        // 握手成功，当前 128-bit 发送完毕
                        if (!empty) begin
                            // 流水线优化：如果 FIFO 还有数据，立刻读下一个
                            fifo_re <= 1;
                            rd_ptr <= rd_ptr + 1;
                            data_cache <= mem[rd_ptr[DEPTH_LOG2-1:0] ]; 
                            state <= S_SEND_LOW;
                            
                        end else begin
                            // FIFO 空了，回到 IDLE
                            axis_tvalid <= 0;
                            state <= S_IDLE;
                        end
                    end
                end
            endcase
        end
    end
    
    // TLAST 处理: 
    // 在加速器设计中，TLAST 通常不是必须的，除非连接了 AXI DMA S2MM 通道且开启了 TLAST 截断。
    // 简单起见，我们这里保持为 0。如果必须，需要增加计数器逻辑。
    always @(*) axis_tlast = 0; 

endmodule