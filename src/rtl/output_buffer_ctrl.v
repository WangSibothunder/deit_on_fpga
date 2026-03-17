// -----------------------------------------------------------------------------
// 文件: src/rtl/output_buffer_ctrl.v
// 说明: 输出缓冲（FIFO + 128b->64b Gearbox）
// -----------------------------------------------------------------------------
// -----------------------------------------------------------------------------
// 规格书索引
// 模块: output_buffer_ctrl
// 规格书: docs/output_buffer_ctrl.md
// 用途: 输出缓冲 FIFO + 128b->64b Gearbox，按帧输出 AXI-Stream
// 关键参数: DEPTH_LOG2=8(默认 256 深度)
// 接口分组:
//   - PPU 写端: i_data/i_valid/o_full
//   - AXI-Stream 读端: axis_tdata/valid/ready/last
//   - 配置: i_cfg_seq_len (帧长度，beat=seq_len*2)
//   - Debug: dbg_obuf_*
// 时序要点:
//   - FIFO 写入无额外延迟，读端 FSM 按 2 拍输出 128b
//   - axis_tlast 在帧末 beat 对齐产生
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module output_buffer_ctrl #(
    parameter DEPTH_LOG2 = 8
)(
    input  wire          clk,
    input  wire          rst_n,

    // PPU Interface (Write Side)
    input  wire [127:0]  i_data,
    input  wire          i_valid,
    output wire          o_full,

    // Frame Length Config (beats = cfg_seq_len*2)
    input  wire [31:0]   i_cfg_seq_len,

    // AXI-Stream Interface (Read Side)
    output reg  [63:0]   axis_tdata,
    output reg           axis_tvalid,
    input  wire          axis_tready,
    output reg           axis_tlast,

    // Debug
    output wire [7:0]    dbg_obuf_wr_ptr,
    output wire [7:0]    dbg_obuf_rd_ptr,
    output wire          dbg_obuf_full
);

    // -------------------------------------------------------------------------
    // 1. FIFO (Width=128, Depth=2^DEPTH_LOG2)
    // -------------------------------------------------------------------------
    localparam DEPTH = 1 << DEPTH_LOG2;

    reg [127:0] mem [0:DEPTH-1];
    reg [DEPTH_LOG2:0] wr_ptr;
    reg [DEPTH_LOG2:0] rd_ptr;

    wire empty = (wr_ptr == rd_ptr);
    wire full  = (wr_ptr[DEPTH_LOG2] != rd_ptr[DEPTH_LOG2]) &&
                 (wr_ptr[DEPTH_LOG2-1:0] == rd_ptr[DEPTH_LOG2-1:0]);

    // o_full 用于上游背压；此实现不丢包但需要上游遵守 o_full

    assign o_full = full;
    assign dbg_obuf_full = full;
    assign dbg_obuf_wr_ptr = wr_ptr[7:0];
    assign dbg_obuf_rd_ptr = rd_ptr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (i_valid && !full) begin
            mem[wr_ptr[DEPTH_LOG2-1:0]] <= i_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // -------------------------------------------------------------------------
    // 2. Read + Gearbox FSM (registered outputs, stable per beat)
    // -------------------------------------------------------------------------
    localparam ST_IDLE  = 2'd0;
    localparam ST_HALF0 = 2'd1;
    localparam ST_HALF1 = 2'd2;

    // 状态含义:
    //   ST_IDLE : 读出 128b，先发低 64b
    //   ST_HALF0: 等待 ready 后发高 64b
    //   ST_HALF1: 完成本 128b，指针+1

    reg [1:0]   state;
    reg [127:0] word_buf;
    reg         frame_active;
    reg [31:0]  beat_cnt;
    reg [31:0]  frame_beats;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr      <= 0;
            state       <= ST_IDLE;
            word_buf    <= 0;
            axis_tvalid <= 0;
            axis_tdata  <= 0;
            axis_tlast  <= 0;
            frame_active <= 0;
            beat_cnt     <= 0;
            frame_beats  <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    axis_tvalid <= 0;
                    axis_tlast  <= 0;
                    if (!empty) begin
                        if (!frame_active) begin
                            frame_active <= 1;
                            beat_cnt     <= 0;
                            frame_beats  <= (i_cfg_seq_len << 1); // cfg*2
                        end
                        word_buf    <= mem[rd_ptr[DEPTH_LOG2-1:0]];
                        axis_tdata  <= mem[rd_ptr[DEPTH_LOG2-1:0]][63:0];
                        axis_tvalid <= 1;
                        axis_tlast  <= (frame_active && (beat_cnt == frame_beats - 1));
                        state       <= ST_HALF0;
                    end
                end
                ST_HALF0: begin
                    if (axis_tvalid && axis_tready) begin
                        beat_cnt   <= beat_cnt + 1;
                        axis_tdata  <= word_buf[127:64];
                        axis_tvalid <= 1;
                        axis_tlast  <= ((beat_cnt + 1) == (frame_beats - 1));
                        state       <= ST_HALF1;
                    end
                end
                ST_HALF1: begin
                    if (axis_tvalid && axis_tready) begin
                        if ((beat_cnt + 1) >= frame_beats) begin
                            frame_active <= 0;
                            beat_cnt     <= 0;
                        end else begin
                            beat_cnt <= beat_cnt + 1;
                        end
                        rd_ptr      <= rd_ptr + 1;
                        axis_tvalid <= 0;
                        axis_tlast  <= 0;
                        state       <= ST_IDLE;
                    end
                end
                default: begin
                    state       <= ST_IDLE;
                    axis_tvalid <= 0;
                    axis_tlast  <= 0;
                end
            endcase
        end
    end

endmodule
