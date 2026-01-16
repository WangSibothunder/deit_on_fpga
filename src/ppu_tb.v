// -----------------------------------------------------------------------------
// 文件名: src/ppu_tb.v
// 描述: PPU 验证平台 (Support Bias)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module ppu_tb;

    localparam NUM_TESTS = 100;

    reg clk, rst_n;
    reg i_valid;
    reg [`ARRAY_COL*32-1:0] i_data_vec;
    wire o_valid;
    wire [`ARRAY_COL*8-1:0] o_data_vec;

    reg [15:0] cfg_mult;
    reg [4:0]  cfg_shift;
    reg [7:0]  cfg_zp;
    reg [31:0] cfg_bias; // NEW

    // Memories
    reg [`ARRAY_COL*32-1:0] mem_inputs [0:NUM_TESTS-1];
    reg [`ARRAY_COL*8-1:0]  mem_golden [0:NUM_TESTS-1];
    reg [31:0]              mem_config [0:3]; // Increased size for Bias

    ppu dut (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_data_vec(i_data_vec),
        .o_valid(o_valid), .o_data_vec(o_data_vec),
        .cfg_mult(cfg_mult), .cfg_shift(cfg_shift), .cfg_zp(cfg_zp),
        .cfg_bias(cfg_bias) // NEW
    );

    always #5 clk = ~clk;

    // Helper
    function signed [7:0] get_byte;
        input [`ARRAY_COL*8-1:0] vec;
        input integer idx;
        begin
            get_byte = vec[(idx*8) +: 8];
        end
    endfunction

    integer i, lane, err_count = 0;

    initial begin
        $dumpfile("ppu_verify.vcd");
        $dumpvars(0, ppu_tb);

        // Load Data
        if (!$test$plusargs("NO_FILE_CHECK")) begin
             $readmemh("src/test_data/ppu_inputs.mem", mem_inputs);
             $readmemh("src/test_data/ppu_golden.mem", mem_golden);
             $readmemh("src/test_data/ppu_config.mem", mem_config);
        end

        // Load Config
        cfg_mult  = mem_config[0][15:0];
        cfg_shift = mem_config[1][4:0];
        cfg_zp    = mem_config[2][7:0];
        cfg_bias  = mem_config[3][31:0]; // NEW
        
        $display("[TB] Config: Mult=%d, Shift=%d, ZP=%d, Bias=%d", 
                 cfg_mult, cfg_shift, cfg_zp, $signed(cfg_bias));

        clk = 0; rst_n = 0; i_valid = 0; i_data_vec = 0;
        #20 rst_n = 1; #20;

        for (i = 0; i < NUM_TESTS; i = i + 1) begin
            @(posedge clk);
            i_valid <= 1;
            i_data_vec <= mem_inputs[i];

            @(posedge clk);
            i_valid <= 0;
            #1; // Wait for output reg

            if (o_valid !== 1) begin
                $display("[FAIL] Vector %0d: o_valid missing", i);
                err_count = err_count + 1;
            end else if (o_data_vec !== mem_golden[i]) begin
                $display("[FAIL] Vector %0d Mismatch!", i);
                // Print detail for Lane 0
                $display("       Lane 0: Input=%d, Bias=%d, Exp=%d, Got=%d", 
                         $signed(mem_inputs[i][31:0]), $signed(cfg_bias),
                         $signed(mem_golden[i][7:0]), $signed(o_data_vec[7:0]));
                err_count = err_count + 1;
            end else begin
                $display("[PASS] Vector %0d: All lanes match!", i);
                $display("       Lane 0: Input=%d, Bias=%d, Exp=%d, Got=%d", 
                         $signed(mem_inputs[i][31:0]), $signed(cfg_bias),
                         $signed(mem_golden[i][7:0]), $signed(o_data_vec[7:0]));
            end
        end

        #20;
        if (err_count == 0) $display("\n=== SUCCESS: All vectors with Bias passed! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_count);
        $finish;
    end
endmodule