// -----------------------------------------------------------------------------
// 文件名: src/weight_buffer_ctrl.v
// 作者: Google FPGA Architect Mentor
// 描述: 权重缓冲控制器 (Gearbox + Ping-Pong LUTRAM)
//       - Input: 64-bit Stream
//       - Output: 128-bit Vector (16 cols x 8 bits)
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
    // Core 的 ctrl_weight_load_en 连接到这里的 i_weight_load_en
    input  wire                         i_weight_load_en,
    output wire [`ARRAY_COL*8-1:0]      o_weight_vec,

    // --- Control ---
    input  wire                         i_bank_swap
);

    // -------------------------------------------------------------------------
    // 1. Constants & Parameters
    // -------------------------------------------------------------------------
    // 12 Rows per tile. Use 16 depth (4 bits) for alignment power of 2
    localparam DEPTH_LOG2 = 4; 
    
    // Output Width: 16 cols * 8 bit = 128 bit
    localparam OUT_WIDTH = `ARRAY_COL * 8;

    assign s_axis_tready = 1'b1; // Always ready

    // -------------------------------------------------------------------------
    // 2. Ping-Pong State
    // -------------------------------------------------------------------------
    reg bank_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) bank_sel <= 0;
        else if (i_bank_swap) bank_sel <= ~bank_sel;
    end

    // -------------------------------------------------------------------------
    // 3. Gearbox (64-bit -> 128-bit)
    // -------------------------------------------------------------------------
    reg        gb_cnt;         // 0: Low Word, 1: High Word
    reg [63:0] temp_low;
    
    reg [OUT_WIDTH-1:0] ram_wdata;
    reg                 ram_wen;
    
    // Write Pointer
    reg [DEPTH_LOG2-1:0] wr_ptr;
    // Pipeline Address (Critical for timing alignment, same as Input Buffer)
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
            ram_wen <= 0; // Default Low

            if (i_bank_swap) begin
                wr_ptr   <= 0;
                gb_cnt   <= 0;
            end 
            else if (s_axis_tvalid) begin
                if (gb_cnt == 0) begin
                    // Cycle 0: Store Low 64 bits
                    temp_low <= s_axis_tdata;
                    gb_cnt   <= 1;
                end else begin
                    // Cycle 1: Combine High + Low -> Write 128 bits
                    // Assuming Little Endian: {High, Low}
                    ram_wdata <= {s_axis_tdata, temp_low}; 
                    ram_wen   <= 1;
                    
                    // Latch current address for pipeline alignment
                    wr_addr_pipe <= wr_ptr;
                    
                    wr_ptr    <= wr_ptr + 1;
                    gb_cnt    <= 0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // 4. Memory (LUTRAM Inference)
    // -------------------------------------------------------------------------
    // Size: 2 Banks * 16 Depth = 32 Total Depth. Width = 128.
    // Xilinx Vivado handles this efficiently using LUTRAM (Distributed Memory)
    reg [OUT_WIDTH-1:0] ram [0:(1<<(DEPTH_LOG2+1))-1];

    // Write Port
    wire [DEPTH_LOG2:0] final_wr_addr = {bank_sel, wr_addr_pipe};

    always @(posedge clk) begin
        if (ram_wen) begin
            ram[final_wr_addr] <= ram_wdata;
        end
    end

    // Read Port
    reg [DEPTH_LOG2-1:0] rd_ptr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else begin
            // Reset read pointer when not loading? 
            // The global_controller asserts load_en for exactly 12 cycles.
            // But it does not provide a reset signal.
            // We can reset rd_ptr when load_en is LOW.
            if (i_weight_load_en) 
                rd_ptr <= rd_ptr + 1;
            else
                rd_ptr <= 0;
        end
    end

    wire [DEPTH_LOG2:0] final_rd_addr = {~bank_sel, rd_ptr};
    
    // Asynchronous Read (LUTRAM characteristic) or Synchronous?
    // LUTRAMs are usually Async Read. But for timing closure, we register the output.
    // Also `deit_core` logic expects data to be valid.
    // Let's use Synchronous Read (Output Register) to match BRAM behavior of Input Buffer.
    reg [OUT_WIDTH-1:0] ram_out_reg;
    always @(posedge clk) begin
        ram_out_reg <= ram[final_rd_addr];
    end

    assign o_weight_vec = ram_out_reg;

endmodule