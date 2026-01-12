// -----------------------------------------------------------------------------
// 文件名: global_controller.v
// 作者: Google FPGA Architect Mentor
// 描述: 系统主控制器。协调权重加载、计算循环和数据输出。
// -----------------------------------------------------------------------------

`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module global_controller (
    input  wire                     clk,
    input  wire                     rst_n,

    // --- 来自 PS (CPU) 的 AXI-Lite 配置信号 ---
    input  wire                     ap_start,       // 启动信号 (脉冲或高电平)
    input  wire [31:0]              cfg_k_dim,      // K 维度大小 (例如 192)
    
    // --- 反馈给 PS 的状态信号 ---
    output reg                      ap_done,        // 计算完成中断
    output reg                      ap_idle,        // 空闲状态指示
    output reg  [2:0]               current_state_dbg, // 调试用：当前状态

    // --- 控制各个子模块的控制信号 ---
    output reg                      ctrl_weight_load_en, // 启用权重加载模式
    output reg                      ctrl_input_stream_en,// 启用输入数据流
    output reg                      ctrl_acc_en,         // 启用累加器
    output reg                      ctrl_drain_en        // 启用结果输出
);

    // -------------------------------------------------------------------------
    // 状态定义 (One-Hot Encoding 推荐用于高性能 FSM，但在低速控制层 Binary 亦可)
    // -------------------------------------------------------------------------
    localparam S_IDLE       = 3'd0;
    localparam S_LOAD_W     = 3'd1; // 加载权重 Tile
    localparam S_COMPUTE    = 3'd2; // 脉动阵列计算中
    localparam S_DRAIN      = 3'd3; // 排空流水线/输出结果
    localparam S_DONE       = 3'd4; // 完成握手

    reg [2:0] state, next_state;

    // -------------------------------------------------------------------------
    // 内部计数器
    // -------------------------------------------------------------------------
    reg [31:0] cnt_k;           // 追踪 K 维度的进度
    reg [31:0] cnt_load_w;      // 追踪权重加载进度
    
    // 假设权重加载需要 `ARRAY_ROW 个周期 (串行推入每一列)
    // 或者如果是并行加载，可能需要 `ARRAY_ROW 个周期将数据填满 Shift Reg
    wire [31:0] TARGET_LOAD_CYCLES = `ARRAY_ROW; 
    
    // 计算周期 = K维度 + 阵列流水线延迟 (Array Latency)
    // 脉动阵列的填充需要时间，我们这里简化模型，假设 K 周期流完输入
    wire [31:0] TARGET_COMPUTE_CYCLES = cfg_k_dim;

    // -------------------------------------------------------------------------
    // 状态机: 状态寄存器更新
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // -------------------------------------------------------------------------
    // 状态机: 下一状态逻辑 (Next State Logic)
    // -------------------------------------------------------------------------
    always @(*) begin
        next_state = state; // 默认保持
        case (state)
            S_IDLE: begin
                if (ap_start) 
                    next_state = S_LOAD_W;
            end

            S_LOAD_W: begin
                // 当权重加载计数器达到目标值，进入计算阶段
                if (cnt_load_w >= TARGET_LOAD_CYCLES - 1)
                    next_state = S_COMPUTE;
            end

            S_COMPUTE: begin
                // 当 K 维度所有输入向量都流过阵列后，进入排水(输出)阶段
                if (cnt_k >= TARGET_COMPUTE_CYCLES - 1)
                    next_state = S_DRAIN;
            end
            
            S_DRAIN: begin
                // 这里为了简化，假设 Drain 需要固定周期 (例如行数 + 流水线深度)
                // 暂时用固定值 10 个周期模拟 Output Drain
                // 实际项目中需要根据 Output Buffer 的 Full/Empty 信号握手
                if (cnt_k >= `ARRAY_ROW + 4) 
                     next_state = S_DONE;
            end

            S_DONE: begin
                // 握手完成，且 Start 信号拉低后回到 IDLE (防止重复触发)
                if (!ap_start)
                    next_state = S_IDLE;
            end
            
            default: next_state = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // 输出逻辑与计数器控制
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_k           <= 0;
            cnt_load_w      <= 0;
            ap_done         <= 0;
            ap_idle         <= 1;
            ctrl_weight_load_en <= 0;
            ctrl_input_stream_en<= 0;
            ctrl_drain_en       <= 0;
        end else begin
            // 默认复位信号
            ap_done <= 0;
            
            case (state)
                S_IDLE: begin
                    ap_idle <= 1;
                    cnt_k <= 0;
                    cnt_load_w <= 0;
                    ctrl_weight_load_en <= 0;
                    ctrl_input_stream_en<= 0;
                    ctrl_drain_en <= 0;
                end

                S_LOAD_W: begin
                    ap_idle <= 0;
                    ctrl_weight_load_en <= 1;
                    cnt_load_w <= cnt_load_w + 1;
                end

                S_COMPUTE: begin
                    ctrl_weight_load_en <= 0; // 锁定权重
                    ctrl_input_stream_en<= 1; // 开始流数据
                    cnt_k <= cnt_k + 1;
                end
                
                S_DRAIN: begin
                    ctrl_input_stream_en <= 0;
                    ctrl_drain_en <= 1;
                    // 在 DRAIN 阶段复用 cnt_k 计数，实际应使用独立计数器
                    cnt_k <= cnt_k + 1; 
                end

                S_DONE: begin
                    ctrl_drain_en <= 0;
                    ap_done <= 1; // 发出完成中断
                    cnt_k <= 0;
                end
            endcase
        end
    end
    
    // 调试输出
    always @(*) current_state_dbg = state;

endmodule