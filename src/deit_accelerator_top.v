// -----------------------------------------------------------------------------
// 文件名: src/deit_accelerator_top.v
// 作者: Google FPGA Architect Mentor
// 描述: DeiT 加速器顶层模块 (Top Level Overlay)
//       - 集成所有子模块
//       - 对外暴露 AXI 接口
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module deit_accelerator_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6 
)(
    // --- Global Interface ---
    input  wire                                 clk,
    input  wire                                 rst_n, // System Reset

    // --- AXI4-Lite Control Interface (S_AXI) ---
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire                                 s_axi_awvalid,
    output wire                                 s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_wdata,
    input  wire [3:0]                           s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output wire                                 s_axi_wready,
    output wire [1:0]                           s_axi_bresp,
    output wire                                 s_axi_bvalid,
    input  wire                                 s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire                                 s_axi_arvalid,
    output wire                                 s_axi_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_rdata,
    output wire [1:0]                           s_axi_rresp,
    output wire                                 s_axi_rvalid,
    input  wire                                 s_axi_rready,

    // --- AXI4-Stream Interfaces (DMA) ---
    
    // 1. Input Stream (Activations & Weights share one port or separate?)
    //    Ideally separate ports for high bandwidth, but Zynq HP ports are limited.
    //    Usually we use ONE DMA for Input (MM2S) and ONE DMA for Output (S2MM).
    //    We need to MUX input data: 
    //    - If loading weights: Stream -> Weight Buffer
    //    - If streaming inputs: Stream -> Input Buffer
    //    Let's use a simple AXI-Stream Demux controlled by State?
    //    Actually, simplest for Phase 5: Two separate input streams if possible,
    //    OR use TDEST/TID sideband signals.
    //    Current simplified design: Assume Software sends Weights first, then Inputs.
    //    We use `ctrl_weight_load_en` to route data.
    
    // RX Channel (From DMA MM2S)
    input  wire [63:0]                          axis_in_tdata,
    input  wire                                 axis_in_tvalid,
    output wire                                 axis_in_tready,
    input  wire                                 axis_in_tlast,
    
    // TX Channel (To DMA S2MM)
    output wire [63:0]                          axis_out_tdata,
    output wire                                 axis_out_tvalid,
    input  wire                                 axis_out_tready,
    output wire                                 axis_out_tlast
);

    // =========================================================================
    // 1. Internal Signals & Interconnects
    // =========================================================================
    
    // Control Signals (AXI Lite -> Core)
    wire        ctrl_ap_start;
    wire        ctrl_soft_rst_n;
    wire [31:0] cfg_seq_len;
    wire        cfg_acc_mode;
    wire        core_ap_done;
    wire        core_ap_idle;
    
    // PPU Config
    wire [15:0] cfg_ppu_mult;
    wire [4:0]  cfg_ppu_shift;
    wire [7:0]  cfg_ppu_zp;
    wire [31:0] cfg_ppu_bias; // [FIX] Now connected
    wire        cfg_output_en; // [NEW] Output gating signal

    // Buffer Control (Core -> Buffers)
    wire        core_weight_load_en;
    wire        core_input_read_en;
    
    // Data Paths
    wire [`ARRAY_ROW*8-1:0]  ibuf_to_core_data; // 96-bit
    wire [`ARRAY_COL*8-1:0]  wbuf_to_core_data; // 128-bit
    wire [`ARRAY_COL*32-1:0] core_to_ppu_data;  // 512-bit (16xINT32)
    
    // PPU Output
    wire [`ARRAY_COL*8-1:0]  ppu_to_obuf_data;  // 128-bit (16xINT8)
    wire                     ppu_valid;

    // Global Reset
    wire sys_rst_n;
    assign sys_rst_n = rst_n & ctrl_soft_rst_n; // Hard & Soft Reset combined

    // =========================================================================
    // 2. AXI-Lite Control Module
    // =========================================================================
    axi_lite_control #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(6) // [FIX]
    ) u_control (
        .clk                    (clk),
        .rst_n                  (rst_n), // Only AXI logic uses raw reset
        // AXI Slave Ports
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        
        // User Ports
        .o_ap_start             (ctrl_ap_start),
        .o_soft_rst_n           (ctrl_soft_rst_n),
        .o_cfg_compute_cycles   (cfg_seq_len),
        .o_cfg_acc_mode         (cfg_acc_mode),
        .i_ap_done              (core_ap_done),
        .i_ap_idle              (core_ap_idle),
        
        .o_ppu_mult             (cfg_ppu_mult),
        .o_ppu_shift            (cfg_ppu_shift),
        .o_ppu_zp               (cfg_ppu_zp),
        .o_ppu_bias             (cfg_ppu_bias),  // [FIX] Connected
        .o_output_en            (cfg_output_en)  // [FIX] Connected
    );

    // =========================================================================
    // 3. Input Stream Demux (Simple Router)
    // =========================================================================
    // 逻辑：
    // - 如果核心请求加载权重 (core_weight_load_en == 1)，数据送往 Weight Buffer
    // - 否则 (默认)，数据送往 Input Buffer
    // 注意：这要求软件必须先发权重，再发数据，且时序严格匹配。
    // 在真实复杂设计中，通常用 AXI-Stream Interconnect 或 TDEST。
    
    // Weight Buffer Interface
    wire [63:0] wbuf_in_data  = axis_in_tdata;
    wire        wbuf_in_valid = axis_in_tvalid & core_weight_load_en;
    
    // Input Buffer Interface
    // 注意：Input Buffer 是 Ping-Pong 的，它需要在 COMPUTE 之前预加载。
    // 但我们的 Core 控制器只有在 Compute 时才拉高 input_stream_en (这是读信号)。
    // 这是一个关键的 Top Level 集成难点：谁控制 Input Buffer 的写？
    
    // [修正架构]: Input Buffer 需要独立的写逻辑。
    // 为了简化 Phase 5，我们假设：
    // 1. Weight Load 阶段：DMA -> Weight Buffer
    // 2. Compute 阶段：DMA -> Input Buffer (Direct Stream to Core via Gearbox)
    // 实际上 Input Buffer 也是 Gearbox。
    
    wire [63:0] ibuf_in_data  = axis_in_tdata;
    // 如果不是在加载权重，那就是在加载输入
    wire        ibuf_in_valid = axis_in_tvalid & (!core_weight_load_en); 

    // Ready Logic: 总是 Ready (假设 Buffer 够快/够大)
    assign axis_in_tready = 1'b1;

    // =========================================================================
    // 4. Input Buffer Controller
    // =========================================================================
    // 为了简单，本次暂不使用 Ping-Pong Swap 逻辑，固定用 Bank 0
    input_buffer_ctrl #(
        .DEPTH_LOG2(8) // 256
    ) u_input_buf (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        .s_axis_tdata   (ibuf_in_data),
        .s_axis_tvalid  (ibuf_in_valid),
        .s_axis_tready  (), // Ignored inside
        .s_axis_tlast   (axis_in_tlast),
        
        .i_rd_en        (core_input_read_en),
        .o_array_vec    (ibuf_to_core_data), // 96-bit to core
        
        .i_bank_swap    (1'b0) // Phase 5 simplified
    );

    // =========================================================================
    // 5. Weight Buffer Controller
    // =========================================================================
    weight_buffer_ctrl u_weight_buf (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        .s_axis_tdata   (wbuf_in_data),
        .s_axis_tvalid  (wbuf_in_valid),
        .s_axis_tready  (),
        
        .i_weight_load_en(core_weight_load_en), // Read Enable from Core
        .o_weight_vec   (wbuf_to_core_data),    // 128-bit to core
        
        .i_bank_swap    (1'b0)
    );

    // =========================================================================
    // 6. DeiT Core (The Engine)
    // =========================================================================
    deit_core #(
        .LATENCY_CFG(28),
        .ADDR_WIDTH(8)
    ) u_core (
        .clk                    (clk),
        .rst_n                  (sys_rst_n),
        .ap_start               (ctrl_ap_start),
        .cfg_compute_cycles     (cfg_seq_len),
        .cfg_acc_mode           (cfg_acc_mode),
        .ap_done                (core_ap_done),
        .ap_idle                (core_ap_idle),
        
        .in_act_vec             (ibuf_to_core_data),
        .in_weight_vec          (wbuf_to_core_data),
        .out_acc_vec            (core_to_ppu_data), // 512-bit INT32
        
        .ctrl_weight_load_en    (core_weight_load_en),
        .ctrl_input_stream_en   (core_input_read_en), // This triggers Input Buffer Read
        
        // Debug ports left open
        .dbg_acc_wr_en(), .dbg_acc_addr(), .dbg_aligned_col0(), .dbg_aligned_col15(), .dbg_raw_col0()
    );

    // =========================================================================
    // 7. Post-Processing Unit (PPU)
    // =========================================================================
    // Core 输出有效信号需要被捕获。
    // Core 没有直接的 valid_out，但我们知道 acc_wr_en (内部信号)。
    // 为了简化，我们让 PPU 始终根据输入是否变化来工作？不，PPU 需要 valid。
    
    // [FIX]: deit_core 需要暴露 `acc_wr_en` 给顶层，作为 PPU 的 Valid 输入。
    // 在 deit_core.v 中，我们已经有 `dbg_acc_wr_en`，它就是内部有效的写使能。
    // 我们可以复用它。
    
    wire core_valid_raw;
    assign core_valid_raw = u_core.dbg_acc_wr_en; 
    
    wire ppu_input_valid;
    assign ppu_input_valid = core_valid_raw & cfg_output_en; // Gated Valid

    ppu u_ppu (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        .i_valid        (ppu_input_valid),
        .i_data_vec     (core_to_ppu_data),
        
        .o_valid        (ppu_valid),
        .o_data_vec     (ppu_to_obuf_data), // 128-bit INT8
        
        .cfg_mult       (cfg_ppu_mult),
        .cfg_shift      (cfg_ppu_shift),
        .cfg_zp         (cfg_ppu_zp),
        .cfg_bias       (cfg_ppu_bias)
    );

    // =========================================================================
    // 8. Output Buffer / Output Stream
    // =========================================================================
    // PPU 输出 128-bit (16 Bytes)。DMA 需要 64-bit。
    // 我们需要一个 2-to-1 Gearbox (P2S)。
    // Logic: 
    // Cycle 0: PPU Valid. Store 128-bit. Output Lower 64-bit.
    // Cycle 1: Output Upper 64-bit.
    
    reg [1:0]  out_state;
    reg [127:0] ppu_out_latched;
    reg [63:0]  axis_tdata_reg;
    reg         axis_tvalid_reg;
    reg         axis_tlast_reg;

    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            out_state <= 0;
            axis_tvalid_reg <= 0;
            axis_tdata_reg <= 0;
            axis_tlast_reg <= 0;
        end else begin
            // Simple Output FSM
            // Assuming DMA is always ready (axis_out_tready = 1)
            case (out_state)
                0: begin
                    if (ppu_valid) begin
                        ppu_out_latched <= ppu_to_obuf_data;
                        
                        // Output Lower 64 bits
                        axis_tdata_reg  <= ppu_to_obuf_data[63:0];
                        axis_tvalid_reg <= 1;
                        axis_tlast_reg  <= 0; // Not last
                        
                        out_state <= 1;
                    end else begin
                        axis_tvalid_reg <= 0;
                    end
                end
                1: begin
                    // Output Upper 64 bits
                    axis_tdata_reg  <= ppu_out_latched[127:64];
                    axis_tvalid_reg <= 1;
                    
                    // Is this the last one?
                    // We need a counter or signal from controller. 
                    // For now, let's keep it simple: no TLAST generation logic yet
                    // or generate TLAST every X packets if needed.
                    // DMA usually counts bytes, so TLAST is optional for S2MM if byte count is fixed.
                    axis_tlast_reg  <= 0; 
                    
                    out_state <= 0;
                end
            endcase
        end
    end

    assign axis_out_tdata  = axis_tdata_reg;
    assign axis_out_tvalid = axis_tvalid_reg;
    assign axis_out_tlast  = axis_tlast_reg;

endmodule