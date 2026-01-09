// -----------------------------------------------------------------------------
// 文件名: global_controller_tb.v
// 描述: 验证 Global Controller 的状态跳转与计数器逻辑
// 运行方法 (macOS/Linux):
//    iverilog -o wave_sim params.vh global_controller.v global_controller_tb.v
//    vvp wave_sim
//    gtkwave controller_check.vcd
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
// `include "params.vh"

module global_controller_tb;

    // --- 信号定义 ---
    reg clk;
    reg rst_n;
    reg ap_start;
    reg [31:0] cfg_k_dim;

    wire ap_done;
    wire ap_idle;
    wire [2:0] current_state_dbg;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    wire ctrl_drain_en;

    // --- 实例化 DUT (Device Under Test) ---
    global_controller dut (
        .clk(clk),
        .rst_n(rst_n),
        .ap_start(ap_start),
        .cfg_k_dim(cfg_k_dim),
        .ap_done(ap_done),
        .ap_idle(ap_idle),
        .current_state_dbg(current_state_dbg),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .ctrl_acc_en(), // 暂时悬空
        .ctrl_drain_en(ctrl_drain_en)
    );

    // --- 时钟生成 (100MHz, Period = 10ns) ---
    always #5 clk = ~clk;

    // --- 测试流程 ---
    initial begin
        // 1. 生成波形文件供 GTKWave 查看
        $dumpfile("controller_check.vcd");
        $dumpvars(0, global_controller_tb);

        // 2. 初始化
        clk = 0;
        rst_n = 0;
        ap_start = 0;
        cfg_k_dim = 32; // 设置一个较小的 K 用于快速仿真

        // 3. 复位释放
        #20 rst_n = 1;
        $display("Time %0t: System Reset Released", $time);

        // 4. 发送 Start 信号
        #20 ap_start = 1;
        $display("Time %0t: AP_START Triggered", $time);
        
        // 保持 Start 信号几个周期 (模拟 CPU 行为)
        #30 ap_start = 0;

        // 5. 等待完成
        wait(ap_done == 1);
        $display("Time %0t: AP_DONE Received! Checkpoint Passed.", $time);

        // 6. 再次检查是否回到 IDLE
        #20;
        if (ap_idle == 1) 
            $display("Time %0t: System correctly returned to IDLE.", $time);
        else 
            $display("Error: System stuck.");

        $finish;
    end
    
    // --- 状态监视器 ---
    always @(current_state_dbg) begin
        case(current_state_dbg)
            0: $display("Time %0t: State -> IDLE", $time);
            1: $display("Time %0t: State -> LOAD_WEIGHTS", $time);
            2: $display("Time %0t: State -> COMPUTE", $time);
            3: $display("Time %0t: State -> DRAIN", $time);
            4: $display("Time %0t: State -> DONE", $time);
        endcase
    end

endmodule