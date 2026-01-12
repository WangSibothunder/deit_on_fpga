// -----------------------------------------------------------------------------
// 文件名: accumulator_tb.v
// 描述: 验证累加器堆的读写与累加功能
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module accumulator_tb;

    reg clk;
    reg rst_n;
    reg [3:0] addr;
    reg wr_en;
    reg acc_mode;
    reg [`ARRAY_COL*`ACC_WIDTH-1:0] in_psum_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] out_acc_vec;

    // DUT
    accumulator_bank dut (
        .clk(clk),
        .rst_n(rst_n),
        .addr(addr),
        .wr_en(wr_en),
        .acc_mode(acc_mode),
        .in_psum_vec(in_psum_vec),
        .out_acc_vec(out_acc_vec)
    );

    always #5 clk = ~clk;

    // Helper to extract col value
    function [`ACC_WIDTH-1:0] get_col_val;
        input integer col_idx;
        input [`ARRAY_COL*`ACC_WIDTH-1:0] vec;
        begin
            get_col_val = vec[(col_idx * `ACC_WIDTH) +: `ACC_WIDTH];
        end
    endfunction

    integer i;

    initial begin
        $dumpfile("accumulator_check.vcd");
        $dumpvars(0, accumulator_tb);

        clk = 0; rst_n = 0;
        addr = 0; wr_en = 0; acc_mode = 0; in_psum_vec = 0;

        #20 rst_n = 1;

        // =========================================================
        // CP1: Overwrite Mode (Initialization)
        // =========================================================
        $display("--- CP1: Testing Overwrite (Init) ---");
        
        // Write 100 to Row 0, Col 0..15
        addr = 0;
        wr_en = 1;
        acc_mode = 0; // Overwrite
        
        // Populate input vector with 100
        for (i = 0; i < `ARRAY_COL; i = i + 1) begin
            in_psum_vec[(i*`ACC_WIDTH) +: `ACC_WIDTH] = 32'd100;
        end
        
        #10; // Tick

        // Check immediate output (LUTRAM async read happens immediately after write? 
        // No, read happens combinational from stored value.
        // At T=0, we write 100. At T=10 (end of cycle), 100 is latched.
        // At T=10+, out_acc should show 100.
        
        wr_en = 0; // Disable write
        #1; // Wait for logic propagation
        
        if (get_col_val(0, out_acc_vec) === 100)
            $display("PASS: Addr 0 initialized to 100");
        else
            $display("FAIL: Addr 0 = %d (Expected 100)", get_col_val(0, out_acc_vec));

        // =========================================================
        // CP2: Accumulate Mode
        // =========================================================
        $display("--- CP2: Testing Accumulate ---");
        
        // Add 50 to Row 0
        addr = 0;
        wr_en = 1;
        acc_mode = 1; // Accumulate
        
        for (i = 0; i < `ARRAY_COL; i = i + 1) begin
            in_psum_vec[(i*`ACC_WIDTH) +: `ACC_WIDTH] = 32'd50;
        end
        
        #10; // Tick (Read 100 -> Add 50 -> Write 150)
        
        wr_en = 0;
        #1; 

        if (get_col_val(0, out_acc_vec) === 150)
            $display("PASS: Accumulation 100 + 50 = 150 Correct");
        else
            $display("FAIL: Accumulation Result = %d (Expected 150)", get_col_val(0, out_acc_vec));

        // =========================================================
        // CP3: Multi-Row Access
        // =========================================================
        $display("--- CP3: Multi-Row Access ---");
        // Write 99 to Row 5
        addr = 5;
        wr_en = 1;
        acc_mode = 0;
        for (i = 0; i < `ARRAY_COL; i = i + 1) begin
            in_psum_vec[(i*`ACC_WIDTH) +: `ACC_WIDTH] = 32'd99;
        end
        #10;
        
        // Read Row 0 again (should still be 150)
        wr_en = 0;
        addr = 0;
        #10;
        if (get_col_val(0, out_acc_vec) === 150)
             $display("PASS: Row 0 data preserved");
        else $display("FAIL: Row 0 data corrupted");

        // Read Row 5
        addr = 5;
        #10;
        if (get_col_val(0, out_acc_vec) === 99)
             $display("PASS: Row 5 written correctly");
        else $display("FAIL: Row 5 = %d", get_col_val(0, out_acc_vec));

        $finish;
    end

endmodule