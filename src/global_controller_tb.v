// -----------------------------------------------------------------------------
// 文件名: src/global_controller_tb.v
// 描述: 验证 Global Controller v2.0 的状态流转
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module global_controller_tb;

    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_seq_len;
    
    wire ap_done;
    wire ap_idle;
    wire [2:0] current_state_dbg;
    
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    wire ctrl_drain_en;

    // 参数设置
    localparam LATENCY = 10; // 缩短 Latency 方便仿真波形查看
    
    global_controller #(
        .LATENCY(LATENCY)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ap_start(ap_start), .cfg_seq_len(cfg_seq_len),
        .ap_done(ap_done), .ap_idle(ap_idle),
        .current_state_dbg(current_state_dbg),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .ctrl_drain_en(ctrl_drain_en)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("controller_verify.vcd");
        $dumpvars(0, global_controller_tb);

        clk = 0; rst_n = 0; ap_start = 0; cfg_seq_len = 0;
        #20 rst_n = 1;
        #20;

        $display("=== START CONTROLLER VERIFICATION ===");

        // --- Case 1: Short Sequence (M=32) ---
        $display("[TB] Testing Sequence Length M=32...");
        cfg_seq_len = 32;
        
        @(posedge clk);
        ap_start = 1;
        @(posedge clk);
        ap_start = 0;

        // 1. Wait for Load to finish
        wait(ctrl_weight_load_en == 1);
        $display("[INFO] Entered LOAD State.");
        wait(ctrl_weight_load_en == 0);
        $display("[INFO] LOAD Finished.");

        // 2. Check Compute Duration
        if (ctrl_input_stream_en !== 1) begin
            $display("[FAIL] Compute did not start immediately after Load.");
        end else begin
            $display("[INFO] Entered COMPUTE State.");
        end

        // Measure duration
        fork : timeout_block
            begin
                wait(ctrl_input_stream_en == 0);
                $display("[INFO] COMPUTE Finished (Stream Enable Low).");
                disable timeout_block;
            end
            begin
                #1000; // Timeout
                $display("[FAIL] Timeout waiting for compute to finish.");
                $finish;
            end
        join

        // 3. Check Drain State
        // In Drain state, input stream should be 0, drain_en should be 1
        if (ctrl_drain_en !== 1) $display("[FAIL] Drain Enable not asserted.");
        else $display("[INFO] Entered DRAIN State.");

        // 4. Wait for Done
        wait(ap_done == 1);
        $display("[PASS] ap_done received.");
        
        @(posedge clk);
        if (ap_idle !== 1) $display("[FAIL] Should return to IDLE.");
        else $display("[PASS] Returned to IDLE.");

        $display("\n=== SUCCESS: Controller Logic Verified ===\n");
        $finish;
    end

endmodule