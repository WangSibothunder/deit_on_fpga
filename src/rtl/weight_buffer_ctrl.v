// -----------------------------------------------------------------------------
// 文件: src/rtl/weight_buffer_ctrl.v
// 说明: 权重缓冲（64b->128b Gearbox + Ping-Pong）
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 规格书索引
// 模块: weight_buffer_ctrl
// 规格书: docs/weight_buffer_ctrl.md
// 用途: 权重缓冲与 64b->128b Gearbox，提供 Ping-Pong 权重预加载
// 关键参数: DEPTH_LOG2=4(每个 Bank 16 行); OUT_WIDTH=ARRAY_COL*8(=128b)
// 接口分组:
//   - AXI-Stream Slave: s_axis_tdata/valid/ready
//   - Core: i_weight_load_en, o_weight_vec, o_dat_valid
//   - Control: i_bank_swap
//   - Debug: dbg_wbuf_*
// 时序要点:
//   - Gearbox: 2 个 64b 组成 1 个 128b 写入
//   - RAM 读延迟 1 拍；o_dat_valid = i_weight_load_en 延迟 2 拍
//   - 读地址采用 lookahead，保证输出对齐 (Data0, Data0, Data1...)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module weight_buffer_ctrl (
    input  wire                         clk,
    input  wire                         rst_n,

    // --- AXI-Stream Slave (From DMA) ---
    input  wire [63:0]                  s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,

    // --- Core Interface (To Systolic Array) ---
    input  wire                         i_weight_load_en,
    output wire [`ARRAY_COL*8-1:0]      o_weight_vec,
    
    // Handshake Signal
    output reg                          o_dat_valid,

    // --- Control ---
    input  wire                         i_bank_swap,

    // --- Debug ---
    output wire [3:0]                   dbg_wbuf_wr_ptr,
    output wire                         dbg_wbuf_ram_wen,
    output wire                         dbg_wbuf_gb_cnt
);

    // -------------------------------------------------------------------------
    // 1. 常量定义
    // -------------------------------------------------------------------------
    localparam DEPTH_LOG2 = 4; 
    localparam OUT_WIDTH = `ARRAY_COL * 8;

    assign s_axis_tready = 1'b1;

    // -------------------------------------------------------------------------
    // 2. Ping-Pong Bank 状态
    // -------------------------------------------------------------------------
    reg bank_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bank_sel <= 0;
        else if (i_bank_swap) bank_sel <= ~bank_sel;
    end

    // -------------------------------------------------------------------------
    // 3. Gearbox (64 -> 128)
    // -------------------------------------------------------------------------
    // gb_cnt=0: 收到第 1 个 64b，暂存到 temp_low
    // gb_cnt=1: 收到第 2 个 64b，与 temp_low 拼成 128b 写入 RAM
    reg        gb_cnt;         
    reg [63:0] temp_low;
    reg [OUT_WIDTH-1:0] ram_wdata;
    reg                 ram_wen;
    reg [DEPTH_LOG2-1:0] wr_ptr;
    reg [DEPTH_LOG2-1:0] wr_addr_pipe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gb_cnt       <= 0;
            temp_low     <= 0;
            ram_wen      <= 0;
            ram_wdata    <= 0;
            wr_ptr       <= 0;
            wr_addr_pipe <= 0;
        end else begin
            ram_wen <= 0; 
            if (i_bank_swap) begin
                // Bank 切换时复位写指针与 Gearbox 状态
                wr_ptr   <= 0;
                gb_cnt   <= 0;
            end 
            else if (s_axis_tvalid) begin
                if (gb_cnt == 0) begin
                    temp_low <= s_axis_tdata;
                    gb_cnt   <= 1;
                end else begin
                    // 形成 128b 一行权重 (高 64b 在前)
                    ram_wdata <= {s_axis_tdata, temp_low}; 
                    ram_wen   <= 1;
                    // 写地址打一拍与 ram_wen 对齐，避免错位
                    wr_addr_pipe <= wr_ptr;
                    wr_ptr    <= wr_ptr + 1;
                    gb_cnt    <= 0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. 存储器 (LUTRAM) + 仿真清零
    // -------------------------------------------------------------------------
    reg [OUT_WIDTH-1:0] ram [0:(1<<(DEPTH_LOG2+1))-1];

    // [CRITICAL FIX] Initialize RAM to 0. 
    // This prevents 'X' propagation if we read past the valid data (cycles 13-15).
    integer i;
    initial begin
        for (i = 0; i < (1<<(DEPTH_LOG2+1)); i = i + 1) begin
            ram[i] = 0;
        end
    end

    // Write Port: 写入当前 bank
    wire [DEPTH_LOG2:0] final_wr_addr = {bank_sel, wr_addr_pipe};
    always @(posedge clk) begin
        if (ram_wen) begin
            ram[final_wr_addr] <= ram_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 5. 读端口 + 对齐 (Lookahead Read)
    // -------------------------------------------------------------------------
    reg [DEPTH_LOG2-1:0] rd_ptr;
    
    // ָ߼ (ֲ)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else begin
            if (o_dat_valid) 
                rd_ptr <= rd_ptr + 1;
            else if (!i_weight_load_en) 
                rd_ptr <= 0;
        end
    end

    // [CRITICAL FIX] Lookahead Address Logic
    // 当 o_dat_valid=1 时，当前周期被消费，读地址前瞻到下一拍
    // 以保证输出序列对齐 (Data0, Data0, Data1...)
    wire [DEPTH_LOG2-1:0] rd_ptr_lookahead = (o_dat_valid) ? (rd_ptr + 1) : rd_ptr;

    // Read Port: 读取对侧 bank
    wire [DEPTH_LOG2:0] final_rd_addr = {~bank_sel, rd_ptr_lookahead};
    
    // Output Register
    reg [OUT_WIDTH-1:0] ram_out_reg;
    always @(posedge clk) begin
        // ʹǰհַȡ
        ram_out_reg <= ram[final_rd_addr];
    end

    assign o_weight_vec = ram_out_reg;

    // Debug taps
    assign dbg_wbuf_wr_ptr = wr_ptr;
    assign dbg_wbuf_ram_wen = ram_wen;
    assign dbg_wbuf_gb_cnt = gb_cnt;

    // -------------------------------------------------------------------------
    // 6. Valid 信号逻辑 (2 Cycle Latency)
    // -------------------------------------------------------------------------
    // i_weight_load_en -> (1拍) -> o_dat_valid_temp -> (1拍) -> o_dat_valid
    // RAM 读: Addr -> (1拍) -> Data，保证 valid 与 data 对齐
    reg o_dat_valid_temp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_dat_valid <= 0;
            o_dat_valid_temp <= 0;
        end 
        else begin
            o_dat_valid_temp <= i_weight_load_en;
            o_dat_valid <= o_dat_valid_temp;
        end
    end

endmodule
