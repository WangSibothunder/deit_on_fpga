// -----------------------------------------------------------------------------
// 文件名: src/ppu.v
// 作者: Google FPGA Architect Mentor
// 描述: 量化后处理单元 (INT32 -> INT8) - Fixed Verilog Style
//       Formula: Clamp( (Input * Mult >> Shift) + ZP )
//       Latency: 1 Cycle (Registered Output)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module ppu (
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Data Path ---
    input  wire                         i_valid,
    input  wire [`ARRAY_COL*32-1:0]     i_data_vec, // 16 x INT32

    output reg                          o_valid,
    output wire [`ARRAY_COL*8-1:0]      o_data_vec, // 16 x INT8

    // --- Configuration (Static during compute) ---
    input  wire [15:0]                  cfg_mult,   // Fixed-point multiplier
    input  wire [4:0]                   cfg_shift,  // Right shift (0..31)
    input  wire [7:0]                   cfg_zp      // Zero Point
);

    // -------------------------------------------------------------------------
    // Parallel Quantization Lanes
    // -------------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < `ARRAY_COL; i = i + 1) begin : PPU_LANE
            
            // 1. Unpack Input
            wire signed [31:0] in_val;
            assign in_val = i_data_vec[(i*32) +: 32];

            // -----------------------------------------------------------------
            // 2. Combinational Logic (Arithmetic Chain)
            // -----------------------------------------------------------------
            
            // Step A: Multiply (32-bit * 16-bit = 48-bit)
            wire signed [47:0] product;
            assign product = $signed(in_val) * $signed(cfg_mult);

            // Step B: Shift
            // >>> 是算术右移，保留符号位
            wire signed [47:0] shifted;
            assign shifted = product >>> cfg_shift;

            // Step C: Add Zero Point
            // ZP 扩展为 48 位有符号数
            wire signed [47:0] with_zp;
            assign with_zp = shifted + $signed({ {40{1'b0}}, cfg_zp }); // ZP usually unsigned 0-255

            // Step D: Clamp / Saturate logic to INT8 [-128, 127]
            wire signed [7:0] clamped_val;
            assign clamped_val = (with_zp > 48'sd127)  ? 8'sd127 :
                                 (with_zp < -48'sd128) ? -8'sd128 :
                                 with_zp[7:0];

            // -----------------------------------------------------------------
            // 3. Sequential Logic (Pipeline Register)
            // -----------------------------------------------------------------
            reg signed [7:0] out_reg;
            
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_reg <= 0;
                end else if (i_valid) begin
                    out_reg <= clamped_val;
                end
            end

            // 4. Pack Output
            assign o_data_vec[(i*8) +: 8] = out_reg;

        end
    endgenerate

    // -------------------------------------------------------------------------
    // Valid Signal Pipeline
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_valid <= 0;
        else        o_valid <= i_valid; // 1 cycle latency matches data path
    end

endmodule