// -----------------------------------------------------------------------------
// 文件名: systolic_array_tb.v
// 描述: 脉动阵列单元测试 (Verilog-2001 兼容版)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module systolic_array_tb;

    // --- 参数定义 ---
    localparam CLK_PERIOD = 10;
    localparam SEQ_LEN    = 32; 
    
    // --- 信号定义 ---
    reg clk;
    reg rst_n;
    reg en_compute;
    reg [`ARRAY_ROW-1:0] row_load_en;
    
    reg  [`ARRAY_ROW*`DATA_WIDTH-1:0] in_act_vec;
    reg  [`ARRAY_COL*`DATA_WIDTH-1:0] in_weight_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0]  out_psum_vec;

    // --- 内存定义 ---
    reg [`ARRAY_COL*`DATA_WIDTH-1:0] mem_weights [0:`ARRAY_ROW-1];
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0] mem_inputs  [0:SEQ_LEN-1];
    reg [`ARRAY_COL*`ACC_WIDTH-1:0]  mem_golden  [0:SEQ_LEN-1];

    // --- 统计变量 ---
    integer err_count = 0;
    integer pass_count = 0;

    // --- DUT 实例化 ---
    systolic_array dut (
        .clk(clk),
        .rst_n(rst_n),
        .en_compute(en_compute),
        .row_load_en(row_load_en),
        .in_act_vec(in_act_vec),
        .in_weight_vec(in_weight_vec),
        .out_psum_vec(out_psum_vec)
    );

    // --- 时钟生成 ---
    always #(CLK_PERIOD/2) clk = ~clk;

    // --- 辅助变量声明 (移出循环) ---
    integer r, c, cycle_cnt;
    integer t_in, t_out;
    reg signed [`ACC_WIDTH-1:0] dut_val;
    reg signed [`ACC_WIDTH-1:0] gold_val;

    // --- 主测试流程 ---
    initial begin
        $dumpfile("src/systolic_array.vcd");
        $dumpvars(0, systolic_array_tb);
        
        $display("[TB] Loading .mem files from src/test_data/ ...");
        // 确保使用绝对路径或相对路径正确
        $readmemh("src/test_data/sa_weights.mem", mem_weights);
        $readmemh("src/test_data/sa_inputs.mem",  mem_inputs);
        $readmemh("src/test_data/sa_golden.mem",  mem_golden);

        clk = 0;
        rst_n = 0;
        en_compute = 0;
        row_load_en = 0;
        in_act_vec = 0;
        in_weight_vec = 0;
        cycle_cnt = 0;

        #(CLK_PERIOD*2) rst_n = 1;
        #(CLK_PERIOD*2);

        // --- Phase 1: 加载权重 ---
        $display("[TB] Phase 1: Loading Weights...");
        for (r = 0; r < `ARRAY_ROW; r = r + 1) begin
            @(posedge clk);
            row_load_en = (1 << r);
            in_weight_vec = mem_weights[r];
        end
        @(posedge clk);
        row_load_en = 0;
        in_weight_vec = 0;
        $display("[TB] Weights Loaded.");

        // --- Phase 2: 注入数据 & 检查输出 ---
        $display("[TB] Phase 2: Streaming Inputs (Skewed) & Checking Outputs...");
        en_compute = 1;

        // 运行 100 个周期
        for (cycle_cnt = 0; cycle_cnt < SEQ_LEN + 30; cycle_cnt = cycle_cnt + 1) begin
            
            // 1. 输入驱动 (Skew Logic)
            for (r = 0; r < `ARRAY_ROW; r = r + 1) begin
                t_in = cycle_cnt - r; // Row Skew
                
                if (t_in >= 0 && t_in < SEQ_LEN) begin
                    // 手动位切片赋值
                    // Verilog-2001 不支持变量索引的部分选择，所以需要用 +: 语法
                    in_act_vec[r*8 +: 8] = mem_inputs[t_in][r*8 +: 8];
                end else begin
                    in_act_vec[r*8 +: 8] = 8'd0;
                end
            end

            // 2. 等待时钟传播
            @(negedge clk); 

            // 3. 输出检查
            // 这里的周期数 cycle_cnt 对应当前时刻
            // 注意：因为我们在 posedge 之后等待了 negedge，所以还是同一个周期内
            // 修正时序计算：
            // 输入 t 在 T_in = t + r 时刻进入 Row r
            // 输出 t 在 T_out = T_in + 12 + c - r (因为流过 r 行需要 r 周期? 不，流过整个阵列需要 12)
            // 让我们复用之前的公式：T_out = t + 12 + c
            // 所以 t = cycle_cnt - 12 - c
            
            for (c = 0; c < `ARRAY_COL; c = c + 1) begin
                t_out = cycle_cnt - `ARRAY_ROW - c; // 12 + c Latency

                if (t_out >= 0 && t_out < SEQ_LEN) begin
                    dut_val  = out_psum_vec[c*32 +: 32];
                    gold_val = mem_golden[t_out][c*32 +: 32];

                    if (dut_val !== gold_val) begin
                        $display("[FAIL] Time %0t (Seq %0d) Col %0d: Expected %d, Got %d", 
                                 $time, t_out, c, $signed(gold_val), $signed(dut_val));
                        err_count = err_count + 1;
                    end else begin
                        $display("[PASS] Time %0t (Seq %0d) Col %0d: Expected %d, Got %d", 
                                 $time, t_out, c, $signed(gold_val), $signed(dut_val));
                        pass_count = pass_count + 1;
                    end
                end
            end
            
            // 回到循环顶部等待下一个 posedge
            @(posedge clk);
        end

        $display("\n------------------------------------------------");
        if (err_count == 0 && pass_count > 0) begin
            $display("[SUCCESS] All %0d checks passed!", pass_count);
            $display("Latency Verified: 12 + Col_Index");
        end else begin
            $display("[FAIL] Found %0d mismatches.", err_count);
        end
        $display("------------------------------------------------\n");
        $finish;
    end

endmodule