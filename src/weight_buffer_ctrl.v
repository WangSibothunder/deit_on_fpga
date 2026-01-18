// -----------------------------------------------------------------------------
// 文件名: src/weight_buffer_ctrl.v
// 修改: Phase 5 Final Fix - Pipeline Alignment & Zero Init
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
    input  wire                         i_bank_swap
);

    // -------------------------------------------------------------------------
    // 1. Constants
    // -------------------------------------------------------------------------
    localparam DEPTH_LOG2 = 4; 
    localparam OUT_WIDTH = `ARRAY_COL * 8;

    assign s_axis_tready = 1'b1;

    // -------------------------------------------------------------------------
    // 2. Ping-Pong State
    // -------------------------------------------------------------------------
    reg bank_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bank_sel <= 0;
        else if (i_bank_swap) bank_sel <= ~bank_sel;
    end

    // -------------------------------------------------------------------------
    // 3. Gearbox (64 -> 128)
    // -------------------------------------------------------------------------
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
                wr_ptr   <= 0;
                gb_cnt   <= 0;
            end 
            else if (s_axis_tvalid) begin
                if (gb_cnt == 0) begin
                    temp_low <= s_axis_tdata;
                    gb_cnt   <= 1;
                end else begin
                    ram_wdata <= {s_axis_tdata, temp_low}; 
                    ram_wen   <= 1;
                    wr_addr_pipe <= wr_ptr;
                    wr_ptr    <= wr_ptr + 1;
                    gb_cnt    <= 0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Memory (LUTRAM) with Zero Init
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

    // Write Port
    wire [DEPTH_LOG2:0] final_wr_addr = {bank_sel, wr_addr_pipe};
    always @(posedge clk) begin
        if (ram_wen) begin
            ram[final_wr_addr] <= ram_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 5. Read Port with Pipeline Alignment (FIXED: Lookahead Read)
    // -------------------------------------------------------------------------
    reg [DEPTH_LOG2-1:0] rd_ptr;
    
    // 指针更新逻辑 (保持不变)
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
    // 如果当前 valid 有效，说明下一拍 ptr 会加 1。
    // 为了让下一拍的数据及时跟上，我们必须提前读 ptr + 1。
    // 否则：若读 ptr，数据会滞后一拍，导致 output 重复 (Data0, Data0, Data1...)
    wire [DEPTH_LOG2-1:0] rd_ptr_lookahead = (o_dat_valid) ? (rd_ptr + 1) : rd_ptr;

    wire [DEPTH_LOG2:0] final_rd_addr = {~bank_sel, rd_ptr_lookahead};
    
    // Output Register
    reg [OUT_WIDTH-1:0] ram_out_reg;
    always @(posedge clk) begin
        // 使用前瞻地址读取
        ram_out_reg <= ram[final_rd_addr];
    end

    assign o_weight_vec = ram_out_reg;

    // -------------------------------------------------------------------------
    // 6. Valid Signal Logic (2 Cycle Latency)
    // -------------------------------------------------------------------------
    // Match the timing: Load_En -> (1 cycle) -> Temp -> (1 cycle) -> Valid
    // RAM:              Addr    -> (1 cycle) -> Data
    // Pointer:          Wait    -> (Wait)    -> Inc
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