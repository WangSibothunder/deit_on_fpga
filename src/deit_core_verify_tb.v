// -----------------------------------------------------------------------------
// 文件名: deit_core_verify_tb.v
// 描述: 使用 Python 生成的向量进行全覆盖验证 (Fix: 使用 Force 读取内部状态)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module deit_core_verify_tb;

    // --- Configuration ---
    localparam CLK_PERIOD = 10;
    localparam TEST_DATA_DIR = "/Users/wangsibo/program/deit_on_fpga/src/test_data/";
    
    localparam M_STEPS = 16;
    localparam K_TILES = 2; 

    // --- Signals ---
    reg clk;
    reg rst_n;
    reg ap_start;
    reg [31:0] cfg_compute_cycles;
    reg cfg_acc_mode;
    wire ap_done;
    wire ap_idle;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec;
    reg [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0]  out_acc_vec;

    // --- File Memory Arrays ---
    reg [`ARRAY_COL*`DATA_WIDTH-1:0] mem_w_t1 [0:11];
    reg [`ARRAY_COL*`DATA_WIDTH-1:0] mem_w_t2 [0:11];
    
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0] mem_in_t1 [0:15];
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0] mem_in_t2 [0:15];
    
    reg [`ARRAY_COL*`ACC_WIDTH-1:0] mem_golden [0:15];

    // --- DUT Instantiation ---
    deit_core dut (
        .clk(clk),
        .rst_n(rst_n),
        .ap_start(ap_start),
        .cfg_compute_cycles(cfg_compute_cycles),
        .cfg_acc_mode(cfg_acc_mode),
        .ap_done(ap_done),
        .ap_idle(ap_idle),
        .in_act_vec(in_act_vec),
        .in_weight_vec(in_weight_vec),
        .out_acc_vec(out_acc_vec),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en)
    );

    // --- Clock ---
    always #(CLK_PERIOD/2) clk = ~clk;

    // --- Internal Counters ---
    integer w_ptr;
    integer in_ptr;
    integer tile_idx;

    // --- Main Test Process ---
    initial begin
        $dumpfile("core_verify.vcd");
        $dumpvars(0, deit_core_verify_tb);

        // 1. Load Files
        $display("[TB] Loading Test Vectors from %s", TEST_DATA_DIR);
        $readmemh({TEST_DATA_DIR, "weights_t1.mem"}, mem_w_t1);
        $readmemh({TEST_DATA_DIR, "inputs_t1.mem"}, mem_in_t1);
        $readmemh({TEST_DATA_DIR, "weights_t2.mem"}, mem_w_t2);
        $readmemh({TEST_DATA_DIR, "inputs_t2.mem"}, mem_in_t2);
        $readmemh({TEST_DATA_DIR, "golden_c.mem"}, mem_golden);

        // 2. Init
        clk = 0; rst_n = 0; ap_start = 0;
        in_act_vec = 0; in_weight_vec = 0;
        cfg_compute_cycles = M_STEPS;
        w_ptr = 0; in_ptr = 0; tile_idx = 0;

        #100 rst_n = 1;

        // ========================================================
        // TILE 1: K=0..11 (Mode = Overwrite)
        // ========================================================
        $display("[TB] Starting Tile 1 (Overwrite)...");
        tile_idx = 1; 
        cfg_acc_mode = 0; 
        w_ptr = 0; in_ptr = 0;

        @(posedge clk); ap_start = 1;
        @(posedge clk); ap_start = 0;

        wait(ap_done);
        $display("[TB] Tile 1 Done.");
        #50;

        // ========================================================
        // TILE 2: K=12..23 (Mode = Accumulate)
        // ========================================================
        $display("[TB] Starting Tile 2 (Accumulate)...");
        tile_idx = 2;
        cfg_acc_mode = 1; 
        w_ptr = 0; in_ptr = 0;

        @(posedge clk); ap_start = 1;
        @(posedge clk); ap_start = 0;

        wait(ap_done);
        $display("[TB] Tile 2 Done.");
        
        // ========================================================
        // CHECK RESULTS
        // ========================================================
        $display("[TB] Verifying Results against Golden...");
        #20;
        
        check_results();

        $finish;
    end

    // --- Reactive Data Feeder Logic ---
    always @(posedge clk) begin
        if (ctrl_weight_load_en) begin
            if (tile_idx == 1)      in_weight_vec <= mem_w_t1[w_ptr];
            else if (tile_idx == 2) in_weight_vec <= mem_w_t2[w_ptr];
            
            if (w_ptr < 11) w_ptr <= w_ptr + 1;
        end else begin
            w_ptr <= 0;
        end

        if (ctrl_input_stream_en) begin
            if (tile_idx == 1)      in_act_vec <= mem_in_t1[in_ptr];
            else if (tile_idx == 2) in_act_vec <= mem_in_t2[in_ptr];
            
            if (in_ptr < 15) in_ptr <= in_ptr + 1;
        end else begin
            in_act_vec <= 0;
            in_ptr <= 0;
        end
    end

    // --- Verification Task (Fixed with Force) ---
    task check_results;
        integer m, c, mismatch_cnt;
        reg [`ACC_WIDTH-1:0] val_dut, val_gold;
        begin
            mismatch_cnt = 0;
            $display("[TB] Checking Accumulator Memory...");

            for (m = 0; m < M_STEPS; m = m + 1) begin
                // --- WHITEBOX TRICK: Force internal address ---
                // 强制接管 DUT 内部的 acc_addr 信号
                // 这允许我们遍历 Accumulator Bank 的所有行，即使 Core 处于 IDLE 状态
                force dut.acc_addr = m;
                
                // 等待组合逻辑传播 (LUTRAM read is async)
                #5; 

                // 此时 dut.out_acc_vec 端口输出的就是第 m 行的数据
                for (c = 0; c < `ARRAY_COL; c = c + 1) begin
                    // 从宽向量中提取第 c 列
                    val_dut = dut.out_acc_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH];
                    
                    // 从 Golden Memory 中提取
                    val_gold = mem_golden[m][(c*`ACC_WIDTH) +: `ACC_WIDTH];
                    
                    if (val_dut !== val_gold) begin
                        $display("[FAIL] Row %0d Col %0d: Expected %d, Got %d", m, c, $signed(val_gold), $signed(val_dut));
                        mismatch_cnt = mismatch_cnt + 1;
                    end
                end
                
                // 释放信号 (虽然下一轮循环会再次 force，但这是好习惯)
                release dut.acc_addr;
            end

            if (mismatch_cnt == 0) begin
                $display("\n=======================================================");
                $display("[SUCCESS] All %0d values matched Golden Model!", M_STEPS * `ARRAY_COL);
                $display("System is Verified for Tiled MatMul (Split-K).");
                $display("=======================================================\n");
            end else begin
                $display("\n[FAIL] Found %0d mismatches.", mismatch_cnt);
                $fatal;
            end
        end
    endtask

endmodule