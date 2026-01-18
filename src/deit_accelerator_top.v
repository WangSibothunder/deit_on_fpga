// -----------------------------------------------------------------------------
// 文件名: src/deit_accelerator_top.v
// 描述: DeiT 加速器顶层模块 (Fixed MUX & Swap Logic)
//       - Fix 1: 使用 core_weight_dma_req 控制 Weight Buffer 写入 (Phase 1)
//       - Fix 2: 使用 core_weight_load_en 上升沿触发 Weight Buffer Swap (Phase 2 Start)
//       - Fix 3: Input Buffer 使用 Start 信号触发 Swap
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
    wire        core_weight_dma_req;  // Phase 1: DMA Request [NEW]
    wire        core_input_read_en;
    
    // Data Paths
    wire [`ARRAY_ROW*8-1:0]  ibuf_to_core_data; 
    wire [`ARRAY_COL*8-1:0]  wbuf_to_core_data; 
    wire [`ARRAY_COL*32-1:0] core_to_ppu_data;  
    wire [`ARRAY_COL*8-1:0]  ppu_to_obuf_data;  
    wire                     ppu_valid;

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

    // --- Demux Logic (Critical Fix) ---
    // If Core requests DMA (Phase 1), route to Weight Buffer.
    // Otherwise, route to Input Buffer.
    wire wbuf_in_valid = axis_in_tvalid & core_weight_dma_req;
    wire ibuf_in_valid = axis_in_tvalid & (!core_weight_dma_req);
    
    assign axis_in_tready = 1'b1;

    // --- Swap Control Signals (Fixed with Reset) ---
    
    // 1. Input Buffer Swap: Trigger on Start (Pre-load done)
    reg ctrl_ap_start_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) ctrl_ap_start_d <= 0; // [FIX] Add Reset
        else ctrl_ap_start_d <= ctrl_ap_start;
    end
    wire start_rising_edge = ctrl_ap_start & ~ctrl_ap_start_d;

    // 捕获 DMA 结束的下降沿
    reg dma_req_d;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) dma_req_d <= 0; // [FIX] Add Reset
        else dma_req_d <= core_weight_dma_req;
    end
    wire dma_done_pulse = ~core_weight_dma_req & dma_req_d;
    wire weight_dat_valid,input_dat_valid;
    // --- Buffers ---
    input_buffer_ctrl #(
        .DEPTH_LOG2(8) 
    ) u_input_buf (
        .clk(clk), .rst_n(sys_rst_n),
        .s_axis_tdata(axis_in_tdata), .s_axis_tvalid(ibuf_in_valid), .s_axis_tready(), .s_axis_tlast(axis_in_tlast),
        .i_rd_en(core_input_read_en), .o_array_vec(ibuf_to_core_data),
        .o_dat_valid(input_dat_valid),
        .i_bank_swap(start_rising_edge) 
    );

    weight_buffer_ctrl u_weight_buf (
        .clk(clk), .rst_n(sys_rst_n),
        .s_axis_tdata(axis_in_tdata), .s_axis_tvalid(wbuf_in_valid), .s_axis_tready(),
        .i_weight_load_en(core_weight_load_en), .o_weight_vec(wbuf_to_core_data),
        .o_dat_valid(weight_dat_valid),
        .i_bank_swap(dma_done_pulse)
    );

    // --- Core ---
    deit_core #(
        .LATENCY_CFG(27),
        .ADDR_WIDTH(8)
    ) u_core (
        .clk(clk), .rst_n(sys_rst_n),
        .ap_start(ctrl_ap_start),
        .cfg_compute_cycles(cfg_seq_len), .cfg_acc_mode(cfg_acc_mode),
        .ap_done(core_ap_done), .ap_idle(core_ap_idle),
        .in_act_vec(ibuf_to_core_data), .in_weight_vec(wbuf_to_core_data),
        .out_acc_vec(core_to_ppu_data),
        .ctrl_weight_load_en(core_weight_load_en),
        .ctrl_weight_dma_req(core_weight_dma_req), // [NEW] Connected
        .ctrl_input_stream_en(core_input_read_en),
        .i_weight_valid(weight_dat_valid),
        .i_input_valid(input_dat_valid),
        .dbg_acc_wr_en(), .dbg_acc_addr(), .dbg_aligned_col0(), .dbg_aligned_col15(), .dbg_raw_col0()
    );

    // --- PPU ---
    wire core_valid_raw = u_core.dbg_acc_wr_en; 
    wire ppu_input_valid = core_valid_raw & cfg_output_en; 

    ppu u_ppu (
        .clk(clk), .rst_n(sys_rst_n),
        .i_valid(ppu_input_valid), .i_data_vec(core_to_ppu_data),
        .o_valid(ppu_valid), .o_data_vec(ppu_to_obuf_data),
        .cfg_mult(cfg_ppu_mult), .cfg_shift(cfg_ppu_shift), .cfg_zp(cfg_ppu_zp), .cfg_bias(cfg_ppu_bias)
    );

    // --- Output Gearbox (128 -> 64) ---
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
            case (out_state)
                0: begin
                    if (ppu_valid) begin
                        ppu_out_latched <= ppu_to_obuf_data;
                        axis_tdata_reg  <= ppu_to_obuf_data[63:0];
                        axis_tvalid_reg <= 1;
                        axis_tlast_reg  <= 0;
                        out_state <= 1;
                    end else begin
                        axis_tvalid_reg <= 0;
                    end
                end
                1: begin
                    axis_tdata_reg  <= ppu_out_latched[127:64];
                    axis_tvalid_reg <= 1;
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