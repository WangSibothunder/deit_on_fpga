// -----------------------------------------------------------------------------
// 文件名: src/ppu_tb.v
// 描述: PPU 验证平台 (基于 Python 生成向量)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module ppu_tb;

    // --- Params ---
    localparam NUM_TESTS = 100;

    // --- Signals ---
    reg clk, rst_n;
    reg i_valid;
    reg [`ARRAY_COL*32-1:0] i_data_vec;
    wire o_valid;
    wire [`ARRAY_COL*8-1:0] o_data_vec;

    reg [15:0] cfg_mult;
    reg [4:0]  cfg_shift;
    reg [7:0]  cfg_zp;

    // --- Memories for Test Data ---
    reg [`ARRAY_COL*32-1:0] mem_inputs [0:NUM_TESTS-1];
    reg [`ARRAY_COL*8-1:0]  mem_golden [0:NUM_TESTS-1];
    reg [31:0]              mem_config [0:2]; // Helper to read config

    // --- DUT ---
    ppu dut (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_data_vec(i_data_vec),
        .o_valid(o_valid), .o_data_vec(o_data_vec),
        .cfg_mult(cfg_mult), .cfg_shift(cfg_shift), .cfg_zp(cfg_zp)
    );

    always #5 clk = ~clk;

    // Helper: Extract byte for error reporting
    function signed [7:0] get_byte;
        input [`ARRAY_COL*8-1:0] vec;
        input integer idx;
        begin
            get_byte = vec[(idx*8) +: 8];
        end
    endfunction

    integer i, lane;
    integer err_count = 0;

    initial begin
        $dumpfile("ppu_verify.vcd");
        $dumpvars(0, ppu_tb);

        // 1. Load Data
        $display("[TB] Loading Test Vectors...");
        if ($test$plusargs("NO_FILE_CHECK")) begin
             // Optional: Skip file check
        end else begin
             $readmemh("src/test_data/ppu_inputs.mem", mem_inputs);
             $readmemh("src/test_data/ppu_golden.mem", mem_golden);
             $readmemh("src/test_data/ppu_config.mem", mem_config);
        end

        // 2. Load Config from file (Lines 0, 1, 2)
        // mem_config is 32-bit wide, take lower bits
        cfg_mult  = mem_config[0][15:0];
        cfg_shift = mem_config[1][4:0];
        cfg_zp    = mem_config[2][7:0];
        
        $display("[TB] Config Loaded: Mult=%d, Shift=%d, ZP=%d", cfg_mult, cfg_shift, cfg_zp);

        // 3. Init
        clk = 0; rst_n = 0; i_valid = 0; i_data_vec = 0;
        #20 rst_n = 1;
        #20;

        $display("[TB] Starting Simulation of %0d vectors...", NUM_TESTS);

        // 4. Main Loop
        for (i = 0; i < NUM_TESTS; i = i + 1) begin
            
            // A. Drive Input
            @(posedge clk);
            i_valid <= 1;
            i_data_vec <= mem_inputs[i];

            // B. Wait for Result (1 cycle latency)
            // Current Cycle: Input driven.
            // Next Cycle: Logic processed, Output register updates at posedge.
            @(posedge clk);
            i_valid <= 0; // Pulse valid for 1 cycle (or keep high for streaming)
            
            // Wait one small delta for valid output to settle (Registered Output)
            #1; 

            if (o_valid !== 1) begin
                $display("[FAIL] Vector %0d: o_valid did not assert!", i);
                err_count = err_count + 1;
            end else begin
                // C. Compare
                if (o_data_vec !== mem_golden[i]) begin
                    $display("[FAIL] Vector %0d Mismatch!", i);
                    $display("       Input Hex: %h", mem_inputs[i]);
                    $display("       Exp Hex:   %h", mem_golden[i]);
                    $display("       Got Hex:   %h", o_data_vec);
                    
                    // Detail Lane Check
                    for (lane = 0; lane < 16; lane = lane + 1) begin
                        if (get_byte(o_data_vec, lane) !== get_byte(mem_golden[i], lane)) begin
                             $display("       -> Lane %0d: Exp %d, Got %d", 
                                      lane, $signed(get_byte(mem_golden[i], lane)), $signed(get_byte(o_data_vec, lane)));
                        end
                    end
                    err_count = err_count + 1;
                end else begin
                    $display("[PASS] Vector %0d: All lanes match!", i);
                    $display("       Input Hex: %h", mem_inputs[i]);
                    $display("       Exp Hex:   %h", mem_golden[i]);
                    $display("       Got Hex:   %h", o_data_vec);
                end
            end
        end

        // 5. Final Report
        #20;
        $display("\n------------------------------------------------");
        if (err_count == 0) begin
            $display("=== SUCCESS: Passed all %0d random vectors! ===", NUM_TESTS);
        end else begin
            $display("=== FAILURE: Found %0d mismatches. ===", err_count);
        end
        $display("------------------------------------------------\n");
        $finish;
    end

endmodule