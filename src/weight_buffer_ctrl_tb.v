// -----------------------------------------------------------------------------
// 文件名: src/weight_buffer_ctrl_tb.v
// 描述: 验证 Weight Buffer (Gearbox 64->128 & Ping-Pong)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module weight_buffer_ctrl_tb;

    reg clk, rst_n;
    reg [63:0] s_axis_tdata;
    reg s_axis_tvalid;
    wire s_axis_tready;
    
    reg i_weight_load_en;
    wire [127:0] o_weight_vec; // 16 * 8 = 128
    reg i_bank_swap;

    // DUT
    weight_buffer_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .i_weight_load_en(i_weight_load_en), .o_weight_vec(o_weight_vec),
        .i_bank_swap(i_bank_swap)
    );

    always #5 clk = ~clk;

    task send_word;
        input [63:0] data;
        begin
            s_axis_tdata <= data;
            s_axis_tvalid <= 1;
            @(posedge clk);
            s_axis_tvalid <= 0;
        end
    endtask

    integer err_cnt = 0;

    initial begin
        $dumpfile("weight_verify.vcd");
        $dumpvars(0, weight_buffer_ctrl_tb);

        clk = 0; rst_n = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0;
        i_weight_load_en = 0; i_bank_swap = 0;

        #20 rst_n = 1;
        #20;

        $display("=== START WEIGHT BUFFER VERIFICATION ===");

        // ---------------------------------------------------------
        // CP1: Write to Bank 0 (Gearbox Test)
        // ---------------------------------------------------------
        // Write Row 0 (128 bits): {High, Low}
        // Low:  64'h11111111_00000000
        // High: 64'h33333333_22222222
        // Result: 128'h33333333_22222222_11111111_00000000
        
        $display("[TB] Writing Row 0 to Bank 0...");
        send_word(64'h11111111_00000000); // Low
        send_word(64'h33333333_22222222); // High (Triggers Write)
        
        // Write Row 1
        // Low:  64'h55555555_44444444
        // High: 64'h77777777_66666666
        $display("[TB] Writing Row 1 to Bank 0...");
        send_word(64'h55555555_44444444); 
        send_word(64'h77777777_66666666); 

        #20;

        // ---------------------------------------------------------
        // CP2: Bank Swap & Read
        // ---------------------------------------------------------
        $display("[TB] Swapping Banks...");
        @(posedge clk); i_bank_swap = 1;
        @(posedge clk); i_bank_swap = 0;

        $display("[TB] Reading from Bank 0...");
        // Enable Read (Simulate Controller)
        i_weight_load_en = 1;
        
        // Latency 1 (Address) -> Latency 2 (Data Out)
        @(posedge clk); 
        @(posedge clk);
        
        // Check Row 0
        if (o_weight_vec === 128'h33333333_22222222_11111111_00000000)
            $display("[PASS] CP2a: Row 0 Correct.");
        else begin
            $display("[FAIL] CP2a: Row 0 Mismatch. Got %h", o_weight_vec);
            err_cnt = err_cnt + 1;
        end

        // Check Row 1 (Next cycle)
        @(posedge clk);
        if (o_weight_vec === 128'h77777777_66666666_55555555_44444444)
            $display("[PASS] CP2b: Row 1 Correct.");
        else begin
            $display("[FAIL] CP2b: Row 1 Mismatch. Got %h", o_weight_vec);
            err_cnt = err_cnt + 1;
        end

        i_weight_load_en = 0;

        // --- Final Report ---
        if (err_cnt == 0) $display("\n=== SUCCESS: All Checkpoints Passed! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        $finish;
    end

endmodule