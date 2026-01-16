// -----------------------------------------------------------------------------
// 文件名: src/ppu.v
// 版本: 1.2 (Added Bias Addition)
// 描述: 量化后处理单元 (INT32 -> INT8)
//       Formula: Clamp( ((Input + Bias) * Mult >> Shift) + ZP )
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

    // --- Configuration (From AXI-Lite) ---
    input  wire [15:0]                  cfg_mult,   // Fixed-point multiplier
    input  wire [4:0]                   cfg_shift,  // Right shift (0..31)
    input  wire [7:0]                   cfg_zp,     // Zero Point
    input  wire [31:0]                  cfg_bias    // Bias (INT32) - NEW
);

    genvar i;
    generate
        for (i = 0; i < `ARRAY_COL; i = i + 1) begin : PPU_LANE
            
            // 1. Unpack Input
            wire signed [31:0] in_val;
            assign in_val = i_data_vec[(i*32) +: 32];

            // -----------------------------------------------------------------
            // 2. Combinational Arithmetic Chain
            // -----------------------------------------------------------------
            
            // Step 0: Add Bias (INT32 + INT32) - NEW
            // 这一步必须在乘法之前，因为 Bias 也是 Accumulator 域的值
            wire signed [31:0] val_biased;
            assign val_biased = in_val + $signed(cfg_bias);

            // Step A: Multiply (32-bit * 16-bit = 48-bit)
            wire signed [47:0] product;
            assign product = val_biased * $signed(cfg_mult);

            // Step B: Shift
            wire signed [47:0] shifted;
            assign shifted = product >>> cfg_shift;

            // Step C: Add Zero Point
            wire signed [47:0] with_zp;
            assign with_zp = shifted + $signed({ {40{1'b0}}, cfg_zp });

            // Step D: Clamp to INT8 [-128, 127]
            wire signed [7:0] clamped_val;
            assign clamped_val = (with_zp > 48'sd127)  ? 8'sd127 :
                                 (with_zp < -48'sd128) ? -8'sd128 :
                                 with_zp[7:0];

            // -----------------------------------------------------------------
            // 3. Pipeline Register
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

    // Valid Pipeline
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) o_valid <= 0;
        else        o_valid <= i_valid;
    end

endmodule