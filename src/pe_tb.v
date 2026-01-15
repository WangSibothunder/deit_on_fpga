// -----------------------------------------------------------------------------
// 文件名: pe_tb.v
// 描述: 验证单个 PE 的功能 (Checkpoint 2)
// 运行: iverilog -o pe_sim.out params.vh pe.v pe_tb.v && vvp pe_sim.out
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"
module pe_tb;

    reg clk;
    reg rst_n;
    reg en_compute;
    reg load_weight;
    reg [`DATA_WIDTH-1:0] in_act;
    reg [`DATA_WIDTH-1:0] in_weight;
    reg [`ACC_WIDTH-1:0]  in_psum;

    wire [`DATA_WIDTH-1:0] out_act;
    wire [`ACC_WIDTH-1:0]  out_psum;

    // 实例化 PE
    pe dut (
        .clk(clk),
        .rst_n(rst_n),
        .en_compute(en_compute),
        .load_weight(load_weight),
        .in_act(in_act),
        .in_weight(in_weight),
        .in_psum(in_psum),
        .out_act(out_act),
        .out_psum(out_psum)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("pe_check.vcd");
        $dumpvars(0, pe_tb);

        // 初始化
        clk = 0; rst_n = 0;
        en_compute = 0; load_weight = 0;
        in_act = 0; in_weight = 0; in_psum = 0;

        #20 rst_n = 1;

        // ---------------------------------------------------------------------
        // Case 1: 加载权重 (Weight = 5)
        // ---------------------------------------------------------------------
        $display("--- Test Case 1: Load Weight = 5 ---");
        #10;
        load_weight = 1;
        in_weight = 8'd5;
        #10; // 等待时钟上升沿锁存
        load_weight = 0;
        in_weight = 0; // 清除输入，证明 PE 用的是内部锁存的 5

        // ---------------------------------------------------------------------
        // Case 2: 计算正数乘法 (Input = 10, Psum_In = 20)
        // 预期: Out = 20 + (10 * 5) = 70
        // ---------------------------------------------------------------------
        $display("--- Test Case 2: Positive Calc (10 * 5 + 20) ---");
        en_compute = 1;
        in_act = 8'd10;
        in_psum = 32'd20;
        #10; // 等待计算完成
        
        if (out_psum === 70) 
            $display("PASS: 20 + 10*5 = %d", out_psum);
        else 
            $display("FAIL: Expected 70, Got %d", out_psum);

        // ---------------------------------------------------------------------
        // Case 3: 计算负数乘法 (Input = -3, Psum_In = 100)
        // INT8: -3 的补码是 8'b11111101 (0xFD)
        // 预期: Out = 100 + (-3 * 5) = 100 - 15 = 85
        // ---------------------------------------------------------------------
        $display("--- Test Case 3: Negative Calc (-3 * 5 + 100) ---");
        in_act = -3; // Verilog 会自动处理补码，但需注意位宽
        in_psum = 32'd100;
        #10;

        if (out_psum === 85) 
            $display("PASS: 100 + (-3)*5 = %d", out_psum);
        else 
            $display("FAIL: Expected 85, Got %d", out_psum);

        // ---------------------------------------------------------------------
        // Case 4: 验证数据传递 (Data Passing)
        // ---------------------------------------------------------------------
        $display("--- Test Case 4: Data Passing ---");
        // 上一拍输入的 -3 应该在这一拍出现在 out_act
        if (out_act === -3 || out_act === 8'hFD)
            $display("PASS: out_act passed correctly.");
        else
            $display("FAIL: out_act not propagating.");

        $finish;
    end

endmodule