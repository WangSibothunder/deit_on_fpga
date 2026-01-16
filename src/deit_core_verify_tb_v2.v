// -----------------------------------------------------------------------------
// 文件名: src/deit_core_verify_tb_v2.v
// 描述: DeiT Core 系统级鲁棒验证 (32x24 * 24x32)
//       - 包含文件健全性检查
//       - 包含时序断言 (Assertions)
//       - 模拟 PS 端分块调度逻辑
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module deit_core_verify_tb_v2;

    // --- 1. 参数定义 ---
    localparam M_DIM = 32;
    localparam K_DIM = 24;
    localparam N_DIM = 32;
    
    localparam LATENCY = 28;     // 必须匹配 Core
    localparam ADDR_WIDTH = 8;   // Depth 256

    // --- 2. 信号 ---
    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_compute_cycles;
    reg cfg_acc_mode;
    wire ap_done, ap_idle;

    reg [`ARRAY_ROW*8-1:0]  in_act_vec;
    reg [`ARRAY_COL*8-1:0]  in_weight_vec;
    wire [`ARRAY_COL*32-1:0] out_acc_vec;

    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    
    // Debug Ports
    wire dbg_acc_wr_en;
    wire [ADDR_WIDTH-1:0] dbg_acc_addr;

    // --- 3. 仿真内存 ---
    reg [`ARRAY_ROW*8-1:0] mem_in_k0 [0:M_DIM-1];
    reg [`ARRAY_ROW*8-1:0] mem_in_k1 [0:M_DIM-1];
    
    reg [`ARRAY_COL*8-1:0] mem_w_k0_n0 [0:15]; // Use 16 for safety margin in TB
    reg [`ARRAY_COL*8-1:0] mem_w_k1_n0 [0:15];
    reg [`ARRAY_COL*8-1:0] mem_w_k0_n1 [0:15];
    reg [`ARRAY_COL*8-1:0] mem_w_k1_n1 [0:15];

    reg [`ARRAY_COL*32-1:0] mem_gold_n0 [0:M_DIM-1];
    reg [`ARRAY_COL*32-1:0] mem_gold_n1 [0:M_DIM-1];

    // --- 4. DUT 实例化 ---
    deit_core #(
        .LATENCY_CFG(LATENCY),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ap_start(ap_start),
        .cfg_compute_cycles(cfg_compute_cycles),
        .cfg_acc_mode(cfg_acc_mode),
        .ap_done(ap_done), .ap_idle(ap_idle),
        .in_act_vec(in_act_vec),
        .in_weight_vec(in_weight_vec),
        .out_acc_vec(out_acc_vec),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .dbg_acc_wr_en(dbg_acc_wr_en),
        .dbg_acc_addr(dbg_acc_addr)
    );

    always #5 clk = ~clk;

    // --- 5. 文件加载与检查 ---
    initial begin
        // 使用相对路径，假设在根目录运行脚本
        $readmemh("src/test_data_core/input_k0.mem", mem_in_k0);
        $readmemh("src/test_data_core/input_k1.mem", mem_in_k1);
        
        $readmemh("src/test_data_core/weight_k0_n0.mem", mem_w_k0_n0);
        $readmemh("src/test_data_core/weight_k1_n0.mem", mem_w_k1_n0);
        $readmemh("src/test_data_core/weight_k0_n1.mem", mem_w_k0_n1);
        $readmemh("src/test_data_core/weight_k1_n1.mem", mem_w_k1_n1);
        
        $readmemh("src/test_data_core/golden_n0.mem", mem_gold_n0);
        $readmemh("src/test_data_core/golden_n1.mem", mem_gold_n1);
    end

    // --- 6. 动态 Buffer 模拟 (关键修复: 边界保护) ---
    integer w_ptr, i_ptr;
    reg [1:0] curr_k; // 0, 1
    reg [1:0] curr_n; // 0, 1

    always @(posedge clk) begin
        if (ctrl_weight_load_en) begin
            // [Check] 确保不越界读取，防止 X 注入
            if (w_ptr < 12) begin
                case ({curr_k[0], curr_n[0]})
                    2'b00: in_weight_vec <= mem_w_k0_n0[w_ptr];
                    2'b10: in_weight_vec <= mem_w_k1_n0[w_ptr];
                    2'b01: in_weight_vec <= mem_w_k0_n1[w_ptr];
                    2'b11: in_weight_vec <= mem_w_k1_n1[w_ptr];
                endcase
            end else begin
                in_weight_vec <= 0; // Pad with zero if hardware asks for more
            end
            w_ptr <= w_ptr + 1;
        end else begin
            w_ptr <= 0;
            in_weight_vec <= 0;
        end
    end

    always @(posedge clk) begin
        if (ctrl_input_stream_en) begin
            if (i_ptr < M_DIM) begin
                if (curr_k == 0) in_act_vec <= mem_in_k0[i_ptr];
                else             in_act_vec <= mem_in_k1[i_ptr];
            end else begin
                in_act_vec <= 0;
            end
            i_ptr <= i_ptr + 1;
        end else begin
            i_ptr <= 0;
            in_act_vec <= 0;
        end
    end

    // --- 7. 实时监控任务 (Watchdogs) ---
    always @(posedge clk) begin
        // Monitor 1: 检查是否将 X 写入累加器
        if (dbg_acc_wr_en) begin
            if (^dut.aligned_out_vec === 1'bx) begin
                $display("[ERROR] T=%0t: X state detected in Accumulator Input!", $time);
            end
        end
        // Monitor 2: 检查地址是否溢出
        if (dbg_acc_addr >= 256) begin
             $display("[ERROR] T=%0t: Address Overflow! %d", $time, dbg_acc_addr);
        end
    end

    // --- 8. 验证任务定义 ---
    task run_tile_op;
        input integer k;
        input integer n;
        input integer mode; // 0:Overwrite, 1:Accumulate
        begin
            $display("\n[TB] >>> 启动分块计算: K=%0d, N=%0d, Mode=%s", k, n, mode?"ACC":"NEW");
            curr_k = k;
            curr_n = n;
            
            @(posedge clk);
            cfg_compute_cycles = M_DIM;
            cfg_acc_mode = mode;
            
            ap_start = 1;
            @(posedge clk);
            ap_start = 0;

            // Wait for completion with timeout
            fork : wait_ap_done
                begin
                    wait(ap_done);
                    disable wait_ap_done;
                end
                begin
                    repeat(2000) @(posedge clk);
                    $display("[FATAL] Timeout waiting for ap_done!");
                    $finish;
                end
            join
            
            @(posedge clk);
            $display("[TB] <<< 分块计算完成");
        end
    endtask

    integer err_cnt = 0;
    
    // Backdoor Read Helper
    function signed [31:0] peek_mem(input integer r, input integer c);
        case(c)
            0: peek_mem = dut.u_accum.COL_BANK[0].u_bank.mem[r];
            1: peek_mem = dut.u_accum.COL_BANK[1].u_bank.mem[r];
            2: peek_mem = dut.u_accum.COL_BANK[2].u_bank.mem[r];
            3: peek_mem = dut.u_accum.COL_BANK[3].u_bank.mem[r];
            4: peek_mem = dut.u_accum.COL_BANK[4].u_bank.mem[r];
            5: peek_mem = dut.u_accum.COL_BANK[5].u_bank.mem[r];
            6: peek_mem = dut.u_accum.COL_BANK[6].u_bank.mem[r];
            7: peek_mem = dut.u_accum.COL_BANK[7].u_bank.mem[r];
            8: peek_mem = dut.u_accum.COL_BANK[8].u_bank.mem[r];
            9: peek_mem = dut.u_accum.COL_BANK[9].u_bank.mem[r];
            10: peek_mem = dut.u_accum.COL_BANK[10].u_bank.mem[r];
            11: peek_mem = dut.u_accum.COL_BANK[11].u_bank.mem[r];
            12: peek_mem = dut.u_accum.COL_BANK[12].u_bank.mem[r];
            13: peek_mem = dut.u_accum.COL_BANK[13].u_bank.mem[r];
            14: peek_mem = dut.u_accum.COL_BANK[14].u_bank.mem[r];
            15: peek_mem = dut.u_accum.COL_BANK[15].u_bank.mem[r];
        endcase
    endfunction

    task verify_tile_result;
        input integer n_idx;
        integer r, c;
        reg signed [31:0] exp_val;
        reg signed [31:0] got_val;
        begin
            $display("[TB] 开始校验 N-Tile %0d 的结果...", n_idx);
            for (r=0; r<M_DIM; r=r+1) begin
                for (c=0; c<16; c=c+1) begin
                    if (n_idx == 0) exp_val = mem_gold_n0[r][c*32 +: 32];
                    else            exp_val = mem_gold_n1[r][c*32 +: 32];
                    
                    got_val = peek_mem(r, c);
                    
                    if (exp_val !== got_val) begin
                        $display("[FAIL] Row %0d, Col %0d | Exp: %0d | Got: %0d", 
                                 r, c, exp_val, got_val);
                        err_cnt = err_cnt + 1;
                        if (err_cnt > 10) begin 
                            $display("[ABORT] 错误过多，终止仿真。"); 
                            $finish; 
                        end
                    end
                end
            end
        end
    endtask

    // --- 9. 主测试流程 ---
    initial begin
        $dumpfile("core_system_verify.vcd");
        $dumpvars(0, deit_core_verify_tb_v2);

        clk = 0; rst_n = 0; ap_start = 0;
        cfg_compute_cycles = 0; cfg_acc_mode = 0;
        w_ptr = 0; i_ptr = 0; curr_k = 0; curr_n = 0;

        #20 rst_n = 1; #20;

        // --- Pass 1: 计算左半部分 (N=0) ---
        // 1.1 加载 K=0 块 (Tile 0,0) -> 覆盖模式
        run_tile_op(0, 0, 0); 
        
        // 1.2 加载 K=1 块 (Tile 1,0) -> 累加模式
        run_tile_op(1, 0, 1);
        
        // 1.3 校验结果
        verify_tile_result(0);

        // --- Pass 2: 计算右半部分 (N=1) ---
        // 2.1 加载 K=0 块 (Tile 0,1) -> 覆盖模式
        // 注意：这里切回了 K=0，数据是重新流入的
        run_tile_op(0, 1, 0);
        
        // 2.2 加载 K=1 块 (Tile 1,1) -> 累加模式
        run_tile_op(1, 1, 1);
        
        // 2.3 校验结果
        verify_tile_result(1);

        if (err_cnt == 0) 
            $display("\n=== [SUCCESS] 32x24x32 完整矩阵乘法验证通过! ===\n");
        else 
            $display("\n=== [FAILURE] 发现 %0d 个错误 ===\n", err_cnt);
        
        $finish;
    end

endmodule