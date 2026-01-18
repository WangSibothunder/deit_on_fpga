// -----------------------------------------------------------------------------
// 文件名: src/deit_accelerator_top.v
// 版本: Phase 5 Final (Integrated Output Buffer & All Fixes)
// 描述: DeiT 加速器顶层模块
//       - 包含 Input/Weight Buffer 的握手连接
//       - 包含 DMA 下降沿触发的 Bank Swap
//       - 包含 Output Buffer (FIFO) 以平滑输出流
//       - LATENCY_CFG 修正为 27
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module deit_accelerator_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6 
)(
    input  wire                                 clk,
    input  wire                                 rst_n, 
    // AXI-Lite
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
    // AXI-Stream
    input  wire [63:0]                          axis_in_tdata,
    input  wire                                 axis_in_tvalid,
    output wire                                 axis_in_tready,
    input  wire                                 axis_in_tlast,
    output wire [63:0]                          axis_out_tdata,
    output wire                                 axis_out_tvalid,
    input  wire                                 axis_out_tready,
    output wire                                 axis_out_tlast
);

    // --- Internal Signals ---
    wire        ctrl_ap_start;
    wire        ctrl_soft_rst_n;
    wire [31:0] cfg_seq_len;
    wire        cfg_acc_mode;
    wire        core_ap_done;
    wire        core_ap_idle;
    
    wire [15:0] cfg_ppu_mult;
    wire [4:0]  cfg_ppu_shift;
    wire [7:0]  cfg_ppu_zp;
    wire [31:0] cfg_ppu_bias; 
    wire        cfg_output_en; 

    // Core Controls
    wire        core_weight_load_en;  // Phase 2: Array Load
    wire        core_weight_dma_req;  // Phase 1: DMA Request
    wire        core_input_read_en;
    
    // Data Paths
    wire [`ARRAY_ROW*8-1:0]  ibuf_to_core_data; 
    wire [`ARRAY_COL*8-1:0]  wbuf_to_core_data; 
    wire [`ARRAY_COL*32-1:0] core_to_ppu_data;  
    wire [`ARRAY_COL*8-1:0]  ppu_to_obuf_data;  
    wire                     ppu_valid;

    // Handshake Signals
    wire                     wbuf_valid_out; // Weight Buffer Valid
    wire                     ibuf_valid_out; // Input Buffer Valid

    // Reset
    wire sys_rst_n;
    assign sys_rst_n = rst_n & ctrl_soft_rst_n; 

    // --- AXI Control ---
    axi_lite_control #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(6) 
    ) u_control (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .o_ap_start(ctrl_ap_start), .o_soft_rst_n(ctrl_soft_rst_n),
        .o_cfg_compute_cycles(cfg_seq_len), .o_cfg_acc_mode(cfg_acc_mode),
        .i_ap_done(core_ap_done), .i_ap_idle(core_ap_idle),
        .o_ppu_mult(cfg_ppu_mult), .o_ppu_shift(cfg_ppu_shift),
        .o_ppu_zp(cfg_ppu_zp), .o_ppu_bias(cfg_ppu_bias), .o_output_en(cfg_output_en)
    );

    // --- Demux Logic ---
    wire wbuf_in_valid = axis_in_tvalid & core_weight_dma_req;
    wire ibuf_in_valid = axis_in_tvalid & (!core_weight_dma_req);
    
    assign axis_in_tready = 1'b1;

    // --- Swap Control Signals (Fixed with Reset) ---
    
    // 1. Input Buffer Swap: Trigger on Start
    reg ctrl_ap_start_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) ctrl_ap_start_d <= 0;
        else ctrl_ap_start_d <= ctrl_ap_start;
    end
    wire start_rising_edge = ctrl_ap_start & ~ctrl_ap_start_d;

    // 2. Weight Buffer Swap: Trigger on DMA Done (Falling Edge of DMA Req)
    reg core_weight_dma_req_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) core_weight_dma_req_d <= 0;
        else core_weight_dma_req_d <= core_weight_dma_req;
    end
    wire weight_dma_done_pulse = ~core_weight_dma_req & core_weight_dma_req_d;

    // --- Buffers ---
    input_buffer_ctrl #(
        .DEPTH_LOG2(8) 
    ) u_input_buf (
        .clk            (clk), .rst_n(sys_rst_n),
        .s_axis_tdata   (axis_in_tdata), 
        .s_axis_tvalid  (ibuf_in_valid), 
        .s_axis_tready  (), 
        .s_axis_tlast   (axis_in_tlast),
        .i_rd_en        (core_input_read_en), 
        .o_array_vec    (ibuf_to_core_data),
        .o_dat_valid    (ibuf_valid_out),    // [Connected]
        .i_bank_swap    (start_rising_edge) 
    );

    weight_buffer_ctrl u_weight_buf (
        .clk            (clk), .rst_n(sys_rst_n),
        .s_axis_tdata   (axis_in_tdata), 
        .s_axis_tvalid  (wbuf_in_valid), 
        .s_axis_tready  (),
        .i_weight_load_en(core_weight_load_en), 
        .o_weight_vec   (wbuf_to_core_data),
        .o_dat_valid    (wbuf_valid_out),    // [Connected]
        .i_bank_swap    (weight_dma_done_pulse)
    );

    // --- Core ---
    deit_core #(
        .LATENCY_CFG(27), // [FIXED] 28 -> 27 to align wr_en with data
        .ADDR_WIDTH(8)
    ) u_core (
        .clk                    (clk), .rst_n(sys_rst_n),
        .ap_start               (ctrl_ap_start),
        .cfg_compute_cycles     (cfg_seq_len), .cfg_acc_mode(cfg_acc_mode),
        .ap_done                (core_ap_done), .ap_idle(core_ap_idle),
        .in_act_vec             (ibuf_to_core_data), 
        .in_weight_vec          (wbuf_to_core_data),
        .i_input_valid          (ibuf_valid_out), // [Connected]
        .i_weight_valid         (wbuf_valid_out), // [Connected]
        .out_acc_vec            (core_to_ppu_data),
        .ctrl_weight_load_en    (core_weight_load_en),
        .ctrl_weight_dma_req    (core_weight_dma_req), 
        .ctrl_input_stream_en   (core_input_read_en),
        .dbg_acc_wr_en(), .dbg_acc_addr(), .dbg_aligned_col0(), .dbg_aligned_col15(), .dbg_raw_col0()
    );

    // --- PPU ---
    // [FIXED] 使用 Write-Through 后的 acc_wr_en 驱动 PPU
    // single_column_bank 已经修改为 Write-Through，所以 wr_en 时数据即有效
    wire core_valid_raw = u_core.dbg_acc_wr_en; 
    wire ppu_input_valid = core_valid_raw & cfg_output_en; 

    ppu u_ppu (
        .clk(clk), .rst_n(sys_rst_n),
        .i_valid(ppu_input_valid), .i_data_vec(core_to_ppu_data),
        .o_valid(ppu_valid), .o_data_vec(ppu_to_obuf_data),
        .cfg_mult(cfg_ppu_mult), .cfg_shift(cfg_ppu_shift), .cfg_zp(cfg_ppu_zp), .cfg_bias(cfg_ppu_bias)
    );

    // --- Output Buffer (FIFO + Gearbox) [NEW] ---
    // 替换了原来脆弱的 reg 状态机
    output_buffer_ctrl #(
        .DEPTH_LOG2(8) // 256 Depth for Safety
    ) u_out_buf (
        .clk            (clk),
        .rst_n          (sys_rst_n),
        // From PPU
        .i_data         (ppu_to_obuf_data),
        .i_valid        (ppu_valid),
        .o_full         (), // Optional debug
        // To AXI-Stream
        .axis_tdata     (axis_out_tdata),
        .axis_tvalid    (axis_out_tvalid),
        .axis_tready    (axis_out_tready),
        .axis_tlast     (axis_out_tlast)
    );

endmodule