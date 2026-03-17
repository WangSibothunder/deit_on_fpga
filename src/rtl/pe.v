// -----------------------------------------------------------------------------
// 文件: src/rtl/pe.v
// 说明: 处理单元 PE（权重驻留 + MAC）
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// 规格书索引
// 模块: pe
// 规格书: docs/pe.md
// 用途: 单个 PE，支持权重驻留、MAC 计算与激活右传
// 接口分组:
//   - Control: en_compute / load_weight
//   - Data: in_act/in_weight/in_psum -> out_act/out_psum
// 时序要点:
//   - load_weight 更新寄存器，计算结果在下一拍生效
//   - en_compute 时，out_act/out_psum 产生 1 拍延迟
// -----------------------------------------------------------------------------
`include "params.vh"

(* use_dsp = "yes" *)
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
    (* use_dsp = "yes" *) wire signed [`ACC_WIDTH-1:0] mac_expr;
    assign mac_expr = $signed(in_psum) + ($signed(in_act) * reg_weight);

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
            // 若 load_weight 与 en_compute 同拍为 1，
            // 本拍计算仍使用旧权重（新权重在此拍写入，下拍生效）
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
                out_psum <= mac_expr;
            end
        end
    end

endmodule
