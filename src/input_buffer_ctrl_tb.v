// -----------------------------------------------------------------------------
// 文件名: src/input_buffer_ctrl_tb.v
// 描述: 验证 Gearbox 和 Ping-Pong 逻辑
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module input_buffer_ctrl_tb;

    reg clk, rst_n;
    reg [63:0] s_axis_tdata;
    reg s_axis_tvalid, s_axis_tlast;
    wire s_axis_tready;
    
    reg i_rd_en;
    wire [95:0] o_array_vec;
    reg i_bank_swap;

    // DUT
    input_buffer_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), 
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .i_rd_en(i_rd_en), .o_array_vec(o_array_vec),
        .i_bank_swap(i_bank_swap)
    );

    always #5 clk = ~clk;

    // Helper task to send 64-bit word
    task send_word;
        input [63:0] data;
        begin
            s_axis_tdata <= data;
            s_axis_tvalid <= 1;
            @(posedge clk);
            // wait for ready if we implemented flow control (we didn't yet)
            s_axis_tvalid <= 0;
        end
    endtask

    integer err_cnt = 0;

    initial begin
        $dumpfile("buffer_verify.vcd");
        $dumpvars(0, input_buffer_ctrl_tb);

        clk = 0; rst_n = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0; s_axis_tlast = 0;
        i_rd_en = 0; i_bank_swap = 0;

        #20 rst_n = 1;
        #20;

        $display("=== START BUFFER VERIFICATION ===");

        // ---------------------------------------------------------
        // CP1: Write to Bank 0 (Gearbox Test)
        // ---------------------------------------------------------
        // We want to write 2 vectors of 96-bit (Total 192 bits).
        // This requires 3 writes of 64-bit.
        // Data Pattern: 
        // Word 1: 0x11111111_00000000 (Hi_Lo)
        // Word 2: 0x33333333_22222222
        // Word 3: 0x55555555_44444444
        //
        // Expected RAM Content:
        // Vec 0 (96b): {22222222, 11111111, 00000000} (Little Endian Assembly)
        // Vec 1 (96b): {55555555, 44444444, 33333333}
        
        $display("[TB] Writing 3x64-bit words to Bank 0...");
        
        // Initial State: Bank Sel = 0 (Write 0, Read 1)
        send_word(64'h11111111_00000000); // 1st
        send_word(64'h33333333_22222222); // 2nd -> Should trigger RAM Write 0
        send_word(64'h55555555_44444444); // 3rd -> Should trigger RAM Write 1

        #20;
        
        // ---------------------------------------------------------
        // CP2: Ping-Pong Swap & Read Verification
        // ---------------------------------------------------------
        $display("[TB] Swapping Banks...");
        @(posedge clk);
        i_bank_swap = 1; // Toggle: Now Write 1, Read 0
        @(posedge clk);
        i_bank_swap = 0;

        $display("[TB] Reading from Bank 0...");
        // Read 0
        i_rd_en = 1;
        @(posedge clk); // Latency 1 (Address setup)
        @(posedge clk); // Latency 2 (Data out)
        
        // Check Vec 0
        // Expect: 0x22222222_11111111_00000000
        if (o_array_vec === 96'h22222222_11111111_00000000) 
            $display("[PASS] CP2a: Vec 0 Data Match.");
        else begin
            $display("[FAIL] CP2a: Expected 22..11..00, Got %h", o_array_vec);
            err_cnt = err_cnt + 1;
        end

        // Read 1
        @(posedge clk); 
        // Check Vec 1
        // Expect: 0x55555555_44444444_33333333
        if (o_array_vec === 96'h55555555_44444444_33333333) 
            $display("[PASS] CP2b: Vec 1 Data Match.");
        else begin
            $display("[FAIL] CP2b: Expected 55..44..33, Got %h", o_array_vec);
            err_cnt = err_cnt + 1;
        end
        
        i_rd_en = 0;

        // ---------------------------------------------------------
        // CP3: Concurrent Read/Write (Ping-Pong Safety)
        // ---------------------------------------------------------
        // Now we are Reading Bank 0. Let's Write to Bank 1 simultaneously.
        // It should NOT corrupt Bank 0 reading (if we were still reading).
        // Let's write Full 1s to Bank 1.
        $display("[TB] Writing to Bank 1 while Bank 0 is active for read...");
        send_word({64{1'b1}});
        send_word({64{1'b1}});
        send_word({64{1'b1}});
        
        // Swap to read Bank 1
        @(posedge clk);
        i_bank_swap = 1; // Now Read 1, Write 0
        @(posedge clk);
        i_bank_swap = 0;
        
        i_rd_en = 1;
        @(posedge clk);
        @(posedge clk);
        
        if (o_array_vec === {96{1'b1}})
             $display("[PASS] CP3: Bank 1 Written Correctly.");
        else begin
             $display("[FAIL] CP3: Bank 1 Data Mismatch. Got %h", o_array_vec);
             err_cnt = err_cnt + 1;
        end

        // --- Final Report ---
        if (err_cnt == 0) $display("\n=== SUCCESS: All Checkpoints Passed! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        $finish;
    end

endmodule