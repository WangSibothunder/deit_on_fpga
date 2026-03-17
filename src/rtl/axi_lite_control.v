// -----------------------------------------------------------------------------
// 文件: src/rtl/axi_lite_control.v
// 说明: AXI4-Lite 从接口寄存器映射与配置控制
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 规格书索引
// 模块: axi_lite_control
// 规格书: docs/axi_lite_control.md
// 用途: AXI4-Lite 从接口，提供寄存器映射与配置/调试访问
// 关键参数: C_S_AXI_DATA_WIDTH=32, C_S_AXI_ADDR_WIDTH=6
// 接口分组:
//   - AXI4-Lite Slave: s_axi_*
//   - Core Control: o_ap_start/o_soft_rst_n/o_cfg_compute_cycles/o_cfg_acc_mode
//   - PPU Config: o_ppu_*
//   - Debug: i_dbg*, o_dbg_snap/o_dbg_clr
// 时序要点:
//   - 写通道采用 AW+W 同拍握手；读通道 AR 后单拍返回
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module axi_lite_control #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6 
)(
    // --- Global Signals ---
    input  wire                                 clk,
    input  wire                                 rst_n,

    // --- AXI4-Lite Slave Interface ---
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire                                 s_axi_awvalid,
    output reg                                  s_axi_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]        s_axi_wdata,
    input  wire [3:0]                           s_axi_wstrb,
    input  wire                                 s_axi_wvalid,
    output reg                                  s_axi_wready,
    output wire [1:0]                           s_axi_bresp,
    output reg                                  s_axi_bvalid,
    input  wire                                 s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire                                 s_axi_arvalid,
    output reg                                  s_axi_arready,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]        s_axi_rdata,
    output wire [1:0]                           s_axi_rresp,
    output reg                                  s_axi_rvalid,
    input  wire                                 s_axi_rready,

    // --- User Interface (To Core) ---
    output reg                                  o_ap_start,            // Pulse, Registered
    output wire                                 o_soft_rst_n,          // [FIX] Changed to wire
    output wire [31:0]                          o_cfg_compute_cycles,  // Wire driven by reg
    output wire                                 o_cfg_acc_mode,        // Wire driven by reg
    input  wire                                 i_ap_done,
    input  wire                                 i_ap_idle,

    // --- User Interface (To PPU) ---
    output wire [15:0]                          o_ppu_mult,
    output wire [4:0]                           o_ppu_shift,
    output wire [7:0]                           o_ppu_zp,
    output wire [31:0]                          o_ppu_bias,   // [FIX] ֮ǰ placeholderڽ߼
    output wire                                 o_output_en,  // [NEW]  PPU

    // --- Debug Interface ---
    input  wire [31:0]                          i_dbg0,
    input  wire [31:0]                          i_dbg1,
    input  wire [31:0]                          i_dbg2,
    input  wire [31:0]                          i_dbg3,
    output reg                                  o_dbg_snap,
    output reg                                  o_dbg_clr

);

    // -------------------------------------------------------------------------
    // Register Map
    // -------------------------------------------------------------------------
    localparam ADDR_CTRL_REG    = 5'h00;
    localparam ADDR_STATUS_REG  = 5'h04;
    localparam ADDR_CFG_K       = 5'h08;
    localparam ADDR_CFG_ACC     = 5'h0C;
    localparam ADDR_VERSION     = 5'h10;
    
    // PPU Registers
    localparam ADDR_PPU_MULT    = 5'h14; 
    localparam ADDR_PPU_SHIFT   = 5'h18; 
    localparam ADDR_PPU_ZP      = 5'h1C; 
    // [NEW] Bias 与 Output Enable 地址
    localparam ADDR_PPU_BIAS    = 6'h20; // 32-bit Bias
    localparam ADDR_OUTPUT_EN   = 6'h24; // 1-bit Enable

    localparam ADDR_DBG_SNAP    = 6'h28; // W1C snapshot
    localparam ADDR_DBG_CLR     = 6'h2C; // W1C clear counters
    localparam ADDR_DBG0        = 6'h30;
    localparam ADDR_DBG1        = 6'h34;
    localparam ADDR_DBG2        = 6'h38;
    localparam ADDR_DBG3        = 6'h3C;
    localparam VERSION_ID       = 32'h20260117;

    // -------------------------------------------------------------------------
    // Internal Registers
    // -------------------------------------------------------------------------
    reg [31:0] reg_ctrl;
    reg [31:0] reg_status;
    reg [31:0] reg_cfg_k;
    reg [31:0] reg_cfg_acc;
    
    reg [31:0] reg_ppu_mult;
    reg [31:0] reg_ppu_shift;
    reg [31:0] reg_ppu_zp;
    reg [31:0] reg_ppu_bias;  // [NEW]
    reg [31:0] reg_output_en; // [NEW]

    reg [31:0] reg_dbg0;
    reg [31:0] reg_dbg1;
    reg [31:0] reg_dbg2;
    reg [31:0] reg_dbg3;

    // -------------------------------------------------------------------------
    // AXI Write Channel
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_awready <= 0; s_axi_wready <= 0; s_axi_bvalid <= 0;
            reg_ctrl <= 0; reg_cfg_k <= 0; reg_cfg_acc <= 0;
            reg_ppu_mult <= 0; reg_ppu_shift <= 0; reg_ppu_zp <= 0;
            o_ap_start <= 0;
            reg_ppu_bias <= 0;
            reg_output_en <= 0;

            reg_dbg0 <= 0; reg_dbg1 <= 0; reg_dbg2 <= 0; reg_dbg3 <= 0;
            o_dbg_snap <= 0; o_dbg_clr <= 0;        end else begin
            // Default: 清除脉冲型寄存器 (o_ap_start / o_dbg_*)
            if (o_ap_start) o_ap_start <= 0;

            if (o_dbg_snap) o_dbg_snap <= 0;
            if (o_dbg_clr) o_dbg_clr <= 0;
            s_axi_awready <= 0; s_axi_wready <= 0;
            
            // Handshake Logic: Wait for both AWVALID and WVALID
            if (!s_axi_awready && !s_axi_wready && s_axi_awvalid && s_axi_wvalid) begin
                s_axi_awready <= 1; s_axi_wready <= 1;
                
                case (s_axi_awaddr[5:2])
                    4'h0: begin // 0x00 CTRL
                        if (s_axi_wstrb[0]) begin
                             if (s_axi_wdata[0]) o_ap_start <= 1; // Trigger Pulse
                             reg_ctrl[1] <= s_axi_wdata[1];       // Soft Reset Level
                        end
                    end
                    4'h1: begin // 0x04 STATUS (W1C for Bit 0)
                        // Clear handled in Status Register Logic to avoid multi-driven reg_status[0]
                    end
                    4'h2: if (s_axi_wstrb[0]) reg_cfg_k <= s_axi_wdata;
                    4'h3: if (s_axi_wstrb[0]) reg_cfg_acc <= s_axi_wdata;
                    
                    // PPU Configs
                    4'h5: if (s_axi_wstrb[0]) reg_ppu_mult <= s_axi_wdata;
                    4'h6: if (s_axi_wstrb[0]) reg_ppu_shift <= s_axi_wdata;
                    4'h7: if (s_axi_wstrb[0]) reg_ppu_zp <= s_axi_wdata;
    // [NEW] Bias 与 Output Enable 地址
                    4'h8: if (s_axi_wstrb[0]) reg_ppu_bias <= s_axi_wdata;  // 0x20
                    4'h9: if (s_axi_wstrb[0]) reg_output_en <= s_axi_wdata; // 0x24
                    4'hA: begin // 0x28 DBG_SNAP
                        if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
                            o_dbg_snap <= 1;
                            reg_dbg0 <= i_dbg0;
                            reg_dbg1 <= i_dbg1;
                            reg_dbg2 <= i_dbg2;
                            reg_dbg3 <= i_dbg3;
                        end
                    end
                    4'hB: begin // 0x2C DBG_CLR
                        if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
                            o_dbg_clr <= 1;
                        end
                    end
                endcase
            end

            // Response Logic
            if (s_axi_awready && s_axi_wready) s_axi_bvalid <= 1;
            else if (s_axi_bready && s_axi_bvalid) s_axi_bvalid <= 0;
        end
    end

    assign s_axi_bresp = 2'b00;

    // -------------------------------------------------------------------------
    // Status Register Logic (Sticky Bits)
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) reg_status <= 0;
        else begin
            reg_status[1] <= i_ap_idle; // Real-time
            
            // Sticky Done Logic
            if (i_ap_done) reg_status[0] <= 1;
            else if (s_axi_awready && s_axi_wvalid && s_axi_awaddr[4:2] == 3'h1 && s_axi_wdata[0]) 
                reg_status[0] <= 0; // Clear on W1C
        end
    end

    // -------------------------------------------------------------------------
    // AXI Read Channel
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0; s_axi_rdata <= 0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid) begin
                s_axi_arready <= 1;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= reg_ctrl;
                    4'h1: s_axi_rdata <= reg_status;
                    4'h2: s_axi_rdata <= reg_cfg_k;
                    4'h3: s_axi_rdata <= reg_cfg_acc;
                    4'h4: s_axi_rdata <= VERSION_ID;
                    4'h5: s_axi_rdata <= reg_ppu_mult;
                    4'h6: s_axi_rdata <= reg_ppu_shift;
                    4'h7: s_axi_rdata <= reg_ppu_zp;
                    4'h8: s_axi_rdata <= reg_ppu_bias; // [NEW]
                    4'h9: s_axi_rdata <= reg_output_en; // [NEW]
                    4'hA: s_axi_rdata <= 32'h0; // DBG_SNAP
                    4'hB: s_axi_rdata <= 32'h0; // DBG_CLR
                    4'hC: s_axi_rdata <= reg_dbg0;
                    4'hD: s_axi_rdata <= reg_dbg1;
                    4'hE: s_axi_rdata <= reg_dbg2;
                    4'hF: s_axi_rdata <= reg_dbg3;
                    default: s_axi_rdata <= 0;
                endcase
            end else begin
                s_axi_arready <= 0;
            end

            if (s_axi_arready && s_axi_arvalid) s_axi_rvalid <= 1;
            else if (s_axi_rready && s_axi_rvalid) s_axi_rvalid <= 0;
        end
    end
    assign s_axi_rresp = 2'b00;

    // -------------------------------------------------------------------------
    // Output Assignments
    // -------------------------------------------------------------------------
    // [FIX] These are now wire assignments driven by internal registers
    assign o_soft_rst_n         = reg_ctrl[1];
    assign o_cfg_compute_cycles = reg_cfg_k;
    assign o_cfg_acc_mode       = reg_cfg_acc[0];
    
    assign o_ppu_mult  = reg_ppu_mult[15:0];
    assign o_ppu_shift = reg_ppu_shift[4:0];
    assign o_ppu_zp    = reg_ppu_zp[7:0];
    // [FIX] Bias 输出连接
    assign o_ppu_bias  = reg_ppu_bias;
    assign o_output_en = reg_output_en[0];

endmodule
