// -----------------------------------------------------------------------------
// File: src/output_buffer_ctrl.v
// Description: Output buffer (FIFO + 128->64 gearbox)
// Note: keep read/gearbox state aligned with AXI handshake.
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

    // AXI-Stream Interface (Read Side)
    output reg  [63:0]   axis_tdata,
    output reg           axis_tvalid,
    input  wire          axis_tready,
    output wire          axis_tlast
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

    assign o_full = full;

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

    reg [1:0]   state;
    reg [127:0] word_buf;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr      <= 0;
            state       <= ST_IDLE;
            word_buf    <= 0;
            axis_tvalid <= 0;
            axis_tdata  <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    axis_tvalid <= 0;
                    if (!empty) begin
                        word_buf    <= mem[rd_ptr[DEPTH_LOG2-1:0]];
                        axis_tdata  <= mem[rd_ptr[DEPTH_LOG2-1:0]][63:0];
                        axis_tvalid <= 1;
                        state       <= ST_HALF0;
                    end
                end
                ST_HALF0: begin
                    if (axis_tvalid && axis_tready) begin
                        axis_tdata  <= word_buf[127:64];
                        axis_tvalid <= 1;
                        state       <= ST_HALF1;
                    end
                end
                ST_HALF1: begin
                    if (axis_tvalid && axis_tready) begin
                        rd_ptr      <= rd_ptr + 1;
                        axis_tvalid <= 0;
                        state       <= ST_IDLE;
                    end
                end
                default: begin
                    state       <= ST_IDLE;
                    axis_tvalid <= 0;
                end
            endcase
        end
    end

    assign axis_tlast = 1'b0;

endmodule
