// -----------------------------------------------------------------------------
// 文件名: src/input_buffer_ctrl.v
// 修改: Phase 5 Final Fix - Pipeline Alignment & Zero Init (Input Buffer)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module input_buffer_ctrl #(
    parameter DEPTH_LOG2 = 8,
    parameter DATA_WIDTH = 64
)(
    input  wire                   clk,
    input  wire                   rst_n,
    
    // AXI-Stream Slave (Write)
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    
    // Core Interface (Read)
    input  wire                   i_rd_en,      
    output wire [95:0]            o_array_vec, 
    
    // [ADD] Handshake Signal
    output reg                    o_dat_valid,

    // Control
    input  wire                   i_bank_swap
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
    reg [DEPTH_LOG2-1:0] wr_addr_pipe; 

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
            ram_wen <= 0; 

            if (i_bank_swap) begin
                wr_ptr   <= 0;
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
                        wr_addr_pipe <= wr_ptr; 
                        wr_ptr    <= wr_ptr + 1;
                        temp_reg[31:0] <= s_axis_tdata[63:32]; 
                        gb_state <= 2;
                    end
                    2: begin
                        // Word 3: Output 2 (Current 64 + Old 32)
                        ram_wdata <= {s_axis_tdata, temp_reg[31:0]};
                        ram_wen   <= 1;
                        wr_addr_pipe <= wr_ptr;
                        wr_ptr    <= wr_ptr + 1;
                        gb_state <= 0; 
                    end
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // 3. Memory Inference with Zero Init
    // -------------------------------------------------------------------------
    reg [95:0] ram [0:(1<<(DEPTH_LOG2+1))-1]; 
    
    // [CRITICAL FIX] Initialize RAM to 0 to prevent X propagation
    integer i;
    initial begin
        for (i = 0; i < (1<<(DEPTH_LOG2+1)); i = i + 1) begin
            ram[i] = 0;
        end
    end
    
    wire [DEPTH_LOG2:0] final_wr_addr = {bank_sel, wr_addr_pipe}; 
    
    always @(posedge clk) begin
        if (ram_wen) begin
            ram[final_wr_addr] <= ram_wdata;
        end
    end

    // -------------------------------------------------------------------------
    // 4. Read Port with Pipeline Alignment
    // -------------------------------------------------------------------------
    reg [DEPTH_LOG2-1:0] rd_ptr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else begin
            if (i_bank_swap) begin
                rd_ptr <= 0; 
            end else begin
                // [FIX] Pointer Freeze: Only advance when Valid is High
                if (o_dat_valid) rd_ptr <= rd_ptr + 1;
                else if (!i_rd_en) rd_ptr <= 0;
            end
        end
    end
    
    // [FIX] Lookahead Address Logic
    // If Valid is High, we are consuming current data, so look ahead to next address
    // to ensure ram_out_reg is ready for the NEXT cycle.
    wire [DEPTH_LOG2-1:0] rd_ptr_lookahead = (o_dat_valid) ? (rd_ptr + 1) : rd_ptr;
    wire [DEPTH_LOG2:0] final_rd_addr = {~bank_sel, rd_ptr_lookahead}; 
    
    reg [95:0] ram_out_reg;
    always @(posedge clk) begin
        ram_out_reg <= ram[final_rd_addr];
    end

    assign o_array_vec = (o_dat_valid)? ram_out_reg : 0;

    // -------------------------------------------------------------------------
    // 5. Valid Signal Logic (2 Cycle Latency)
    // -------------------------------------------------------------------------
    // Input Buffer Gearbox adds latency? 
    // Even if pre-loaded, using a consistent handshake ensures alignment.
    reg [1:0] valid_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_sr <= 0;
            o_dat_valid <= 0;
        end else begin
            valid_sr <= {valid_sr[0], i_rd_en};
            o_dat_valid <= valid_sr[1]; 
        end
    end

endmodule