// -----------------------------------------------------------------------------
// 文件名: src/accumulator_tb.v
// 版本: 1.1 (Fixed Sampling Timing)
// 描述: 验证 Accumulator Bank 的深度是否足以支持 197 序列
//       - 修改: 在 negedge clk 采样，避免竞争冒险
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module accumulator_tb;

    // 必须与 single_column_bank 和 accumulator_bank 的参数一致
    localparam ADDR_WIDTH = 8; // Depth 256

    reg clk, rst_n;
    reg [ADDR_WIDTH-1:0] addr;
    reg wr_en;
    reg acc_mode;
    reg [`ARRAY_COL*`ACC_WIDTH-1:0] in_psum_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] out_acc_vec;

    // DUT
    accumulator_bank #(
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .addr(addr), .wr_en(wr_en), .acc_mode(acc_mode),
        .in_psum_vec(in_psum_vec), .out_acc_vec(out_acc_vec)
    );

    always #5 clk = ~clk;

    // Helper: set all cols to specific value
    task set_input_all;
        input [31:0] val;
        integer i;
        begin
            for (i=0; i<`ARRAY_COL; i=i+1) begin
                in_psum_vec[(i*32) +: 32] = val;
            end
        end
    endtask

    integer err_cnt = 0;

    initial begin
        $dumpfile("accum_deep_verify.vcd");
        $dumpvars(0, accumulator_tb);

        clk = 0; rst_n = 0; addr = 0; wr_en = 0; acc_mode = 0; in_psum_vec = 0;
        #20 rst_n = 1; #20;

        $display("=== START DEEP ACCUMULATOR VERIFICATION ===");

        // --- Step 1: Write to Addr 0 (Base) ---
        // 在上升沿前建立数据
        @(negedge clk);
        $display("[TB] Writing value 100 to Addr 0");
        addr = 0; wr_en = 1; acc_mode = 0; // Overwrite
        set_input_all(100);
        @(posedge clk); // Write happens here

        // --- Step 2: Write to Addr 16 ---
        @(negedge clk);
        $display("[TB] Writing value 200 to Addr 16");
        addr = 16; 
        set_input_all(200);
        @(posedge clk); // Write happens here

        // --- Step 3: Write to Addr 196 ---
        @(negedge clk);
        $display("[TB] Writing value 300 to Addr 196");
        addr = 196;
        set_input_all(300);
        @(posedge clk); // Write happens here

        // Disable Write
        @(negedge clk);
        wr_en = 0;

        // --- Step 4: Verify Data Retention ---
        // 关键修改：在地址变化后，等待半个周期(negedge)再检查
        // 这样可以确保组合逻辑读取 (assign out = mem[addr]) 已经完全稳定
        
        // 4.1 Check Addr 0
        addr = 0;
        @(negedge clk); 
        if (out_acc_vec[31:0] === 100) 
            $display("[PASS] Addr 0 is intact (100).");
        else begin
            $display("[FAIL] Addr 0 corrupted! Got %d (Expected 100).", out_acc_vec[31:0]);
            err_cnt = err_cnt + 1;
        end

        // 4.2 Check Addr 16
        addr = 16;
        @(negedge clk);
        if (out_acc_vec[31:0] === 200) 
            $display("[PASS] Addr 16 readback correct (200).");
        else begin 
            $display("[FAIL] Addr 16 mismatch! Got %d (Expected 200).", out_acc_vec[31:0]); 
            err_cnt = err_cnt + 1; 
        end

        // 4.3 Check Addr 196
        addr = 196; 
        @(negedge clk);
        if (out_acc_vec[31:0] === 300) 
            $display("[PASS] Addr 196 readback correct (300).");
        else begin 
            $display("[FAIL] Addr 196 mismatch! Got %d (Expected 300).", out_acc_vec[31:0]); 
            err_cnt = err_cnt + 1; 
        end

        if (err_cnt == 0) $display("\n=== SUCCESS: Accumulator Depth Upgrade Verified! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        $finish;
    end

endmodule