// -----------------------------------------------------------------------------
// 文件名: src/input_buffer_ctrl.v
// 作者: Google FPGA Architect Mentor
// 描述: 输入缓冲控制器 (Fixed for Pipeline Alignment)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module input_buffer_ctrl #(
    parameter DEPTH_LOG2 = 8  
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // --- AXI-Stream Slave Interface ---
    input  wire [63:0]                  s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready, 
    input  wire                         s_axis_tlast, 

    // --- Core Interface ---
    input  wire                         i_rd_en,      
    output wire [`ARRAY_ROW*8-1:0]      o_array_vec,   

    // --- Control Interface ---
    input  wire                         i_bank_swap    
);

    // -------------------------------------------------------------------------
    // 1. Ping-Pong State
    // -------------------------------------------------------------------------
    reg bank_sel; 
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bank_sel <= 0;
        else if (i_bank_swap) bank_sel <= ~bank_sel;
    end

    // -------------------------------------------------------------------------
    // 2. Gearbox Logic (64-bit -> 96-bit)
    // -------------------------------------------------------------------------
    reg [1:0]  gb_state; 
    reg [95:0] ram_wdata;
    reg        ram_wen;
    
    reg [DEPTH_LOG2-1:0] wr_ptr;
    reg [DEPTH_LOG2-1:0] wr_addr_pipe; // FIX: 新增地址流水线寄存器

    reg [63:0] temp_reg;

    assign s_axis_tready = 1'b1; 

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gb_state     <= 0;
            wr_ptr       <= 0;
            wr_addr_pipe <= 0;
            ram_wen      <= 0;
            ram_wdata    <= 0;
            temp_reg     <= 0;
        end else begin
            ram_wen <= 0; // Pulse default low

            if (i_bank_swap) begin
                wr_ptr <= 0;
                gb_state <= 0;
            end
            else if (s_axis_tvalid) begin
                case (gb_state)
                    0: begin 
                        // Word 1: Store only
                        temp_reg <= s_axis_tdata; 
                        gb_state <= 1;
                    end
                    1: begin
                        // Word 2: Output 1 (Low 32 of current + Old 64)
                        ram_wdata <= {s_axis_tdata[31:0], temp_reg};
                        ram_wen   <= 1;
                        
                        // FIX: 记录当前的 wr_ptr 用于下一拍写入
                        wr_addr_pipe <= wr_ptr; 
                        
                        // 指针加 1，为下一次数据做准备
                        wr_ptr    <= wr_ptr + 1;
                        
                        // Store High 32
                        temp_reg[31:0] <= s_axis_tdata[63:32]; 
                        gb_state <= 2;
                    end
                    2: begin
                        // Word 3: Output 2 (Current 64 + Old 32)
                        ram_wdata <= {s_axis_tdata, temp_reg[31:0]};
                        ram_wen   <= 1;
                        
                        // FIX: 记录当前的 wr_ptr
                        wr_addr_pipe <= wr_ptr;
                        
                        wr_ptr    <= wr_ptr + 1;
                        
                        gb_state <= 0; 
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Memory Inference
    // -------------------------------------------------------------------------
    reg [95:0] ram [0:(1<<(DEPTH_LOG2+1))-1]; 
    
    // FIX: 使用 wr_addr_pipe 而不是 wr_ptr
    // 这样，当 ram_wen 在下一拍生效时，地址也是上一拍锁存下来的正确地址 (0)
    // 而不是已经自增后的新地址 (1)
    wire [DEPTH_LOG2:0] final_wr_addr = {bank_sel, wr_addr_pipe}; 
    
    always @(posedge clk) begin
        if (ram_wen) begin
            ram[final_wr_addr] <= ram_wdata;
        end
    end

    // --- Read Port ---
    reg [DEPTH_LOG2-1:0] rd_ptr;
    wire [DEPTH_LOG2:0] final_rd_addr = {~bank_sel, rd_ptr}; 
    reg [95:0] ram_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else begin
            if (i_bank_swap) begin
                rd_ptr <= 0; 
            end else if (i_rd_en) begin
                rd_ptr <= rd_ptr + 1;
            end
        end
    end
    
    always @(posedge clk) begin
        ram_out_reg <= ram[final_rd_addr];
    end

    assign o_array_vec = ram_out_reg;

endmodule