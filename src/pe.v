// -----------------------------------------------------------------------------
// 文件名: pe.v
// 描述: Weight Stationary 处理单元
// 功能: 
//    1. Load Mode: 锁存权重 (reg_weight <= in_weight)
//    2. Compute Mode: out_psum = in_psum + (in_act * reg_weight)
//    3. Data Pass: 将输入 Activation 向右传递 (out_act <= in_act)
// -----------------------------------------------------------------------------

`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module pe (
    input  wire                     clk,
    input  wire                     rst_n,

    // --- 控制信号 ---
    // en_compute: 启用 MAC 运算 (流水线使能)
    // load_weight: 启用权重加载 (权重更新)
    input  wire                     en_compute,
    input  wire                     load_weight,

    // --- 数据通路 ---
    input  wire [`DATA_WIDTH-1:0]   in_act,    // 来自左侧 PE 的输入特征
    input  wire [`DATA_WIDTH-1:0]   in_weight, // 只有在 load_weight 有效时才使用
    input  wire [`ACC_WIDTH-1:0]    in_psum,   // 来自上方 PE 的部分和

    output reg  [`DATA_WIDTH-1:0]   out_act,   // 传递给右侧 PE
    output reg  [`ACC_WIDTH-1:0]    out_psum   // 传递给下方 PE
);

    // 内部权重寄存器
    reg signed [`DATA_WIDTH-1:0] reg_weight;

    // -------------------------------------------------------------------------
    // 核心逻辑
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_weight <= 0;
            out_act    <= 0;
            out_psum   <= 0;
        end else begin
            // 1. 权重加载逻辑 (优先级高，或互斥)
            if (load_weight) begin
                reg_weight <= $signed(in_weight);
                // 在加载权重时，通常为了形成移位链，out_act 也可以用来传递权重
                // 但在本架构中，我们假设权重是单独加载或广播的，或者利用 act 路径
                // 这里为了简单，保持 act 通路清零或保持
            end

            // 2. 计算与数据传递逻辑
            if (en_compute) begin
                // Systolic Data Passing: 将输入特征打一拍传给右边
                out_act <= in_act;

                // MAC Operation: 乘加运算
                // 关键点: 必须使用 $signed 确保综合为有符号乘法
                // Zynq DSP48E1 支持 (A*B+C) 的单周期完成
                out_psum <= $signed(in_psum) + ($signed(in_act) * reg_weight);
            end
        end
    end

endmodule