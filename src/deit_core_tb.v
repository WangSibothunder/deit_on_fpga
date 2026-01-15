// -----------------------------------------------------------------------------
// 文件名: deit_core_tb.v
// 描述: Core Integration 验证
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module deit_core_tb;

    reg clk;
    reg rst_n;
    reg ap_start;
    reg [31:0] cfg_compute_cycles;
    reg cfg_acc_mode;
    wire ap_done;
    wire ap_idle;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;

    // Data mocks
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec;
    reg [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0]  out_acc_vec;

    // DUT
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

    always #5 clk = ~clk;

    // --- Helper to extract output ---
    function [`ACC_WIDTH-1:0] get_out_col;
        input integer c;
        get_out_col = out_acc_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH];
    endfunction

    integer i;

    initial begin
        $dumpfile("core_check.vcd");
        $dumpvars(0, deit_core_tb);

        clk = 0; rst_n = 0; ap_start = 0;
        in_act_vec = 0; in_weight_vec = 0;
        cfg_compute_cycles = 16; // Process 16 input vectors
        cfg_acc_mode = 0; // Overwrite mode

        #20 rst_n = 1;

        // --- Start Transaction ---
        $display("--- Starting Core Transaction ---");
        #10 ap_start = 1;
        #10 ap_start = 0;

        // --- Driver Loop ---
        // 我们需要由 Testbench 模拟 Buffer 的行为，响应 Core 的控制信号
        // 这是一个简单的 Reactive Testbench
        
        // Timeout watchdog
        fork
            begin
                wait(ap_done);
                $display("--- Transaction Done ---");
            end
            begin
                #5000;
                $display("--- TIMEOUT ---");
                $finish;
            end
        join

        // 检查结果 (Check Address 0 of Accumulator)
        // 此时 Core 已完成，地址指针归零，或者我们可以读最后一次写入的值
        // 由于是 LUTRAM，我们可以随时读。
        // 但我们要看的是最后写入 RAM 的值。
        // 简单起见，我们看波形或者这里的打印。
        
        $display("Simulated finish. Check VCD for detailed timing alignment.");
        $finish;
    end

    // --- Reactive Data Feeder ---
    always @(posedge clk) begin
        // Feed Weights
        if (ctrl_weight_load_en) begin
            // 简单喂入：Col 0 = 1, Col 1 = 1 ...
            for (i=0; i<`ARRAY_COL; i=i+1)
                in_weight_vec[i*8 +: 8] = 1; 
        end
        
        // Feed Activations
        if (ctrl_input_stream_en) begin
            // 简单喂入：Row 0..11 = 1
            for (i=0; i<`ARRAY_ROW; i=i+1)
                in_act_vec[i*8 +: 8] = 1; 
        end else begin
            in_act_vec = 0;
        end
    end

endmodule