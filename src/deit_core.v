// -----------------------------------------------------------------------------
// 文件名: deit_core.v
// 描述: 加速器核心层集成 (已修复: 添加输入数据倾斜对齐逻辑)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"

module deit_core (
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Control Interface ---
    input  wire                         ap_start,
    input  wire [31:0]                  cfg_compute_cycles,
    input  wire                         cfg_acc_mode,
    output wire                         ap_done,
    output wire                         ap_idle,

    // --- Data Streams ---
    input  wire [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec,
    input  wire [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec,
    output wire [`ARRAY_COL*`ACC_WIDTH-1:0]   out_acc_vec,
    
    output wire                         ctrl_weight_load_en,
    output wire                         ctrl_input_stream_en
);

    // 1. Instantiate Controller
    wire ctrl_drain_en_unused;
    
    global_controller u_controller (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .ap_start               (ap_start),
        .cfg_k_dim              (cfg_compute_cycles),
        .ap_done                (ap_done),
        .ap_idle                (ap_idle),
        .current_state_dbg      (),
        .ctrl_weight_load_en    (ctrl_weight_load_en),
        .ctrl_input_stream_en   (ctrl_input_stream_en),
        .ctrl_drain_en          (ctrl_drain_en_unused)
    );

    // 2. Glue Logic: Row Load Enable (Shift Register)
    reg [`ARRAY_ROW-1:0] row_load_en;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) row_load_en <= 0;
        else begin
            if (ctrl_weight_load_en) begin
                if (row_load_en == 0) row_load_en <= 1;
                else row_load_en <= (row_load_en << 1);
            end else begin
                row_load_en <= 0;
            end
        end
    end

    // =========================================================================
    // 3. FIX: Input Skew Buffer (三角延迟链)
    // =========================================================================
    // Row 0 延迟 0 拍，Row 1 延迟 1 拍 ... Row 11 延迟 11 拍
    // 这样才能配合 Partial Sum 的垂直流动时序
    
    wire [`ARRAY_ROW*`DATA_WIDTH-1:0] skewed_in_act_vec;

    genvar i;
    generate
        for (i = 0; i < `ARRAY_ROW; i = i + 1) begin : INPUT_SKEW_LOGIC
            if (i == 0) begin
                // 第一行无需延迟
                assign skewed_in_act_vec[(i*`DATA_WIDTH) +: `DATA_WIDTH] 
                     = in_act_vec[(i*`DATA_WIDTH) +: `DATA_WIDTH];
            end else begin
                // 第 i 行需要 i 个周期的延迟
                // 定义一个深度为 i，位宽为 DATA_WIDTH 的移位寄存器链
                reg [(i*`DATA_WIDTH)-1:0] delay_chain;
                
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) delay_chain <= 0;
                    else begin
                        // 移位逻辑: 左移一个 DATA_WIDTH，低位补入新数据
                        // 如果深度为 1 (i=1): delay_chain <= in_data
                        // 如果深度为 2 (i=2): delay_chain <= {delay_chain[7:0], in_data}
                        if (i == 1) begin
                            delay_chain <= in_act_vec[(i*`DATA_WIDTH) +: `DATA_WIDTH];
                        end else begin
                            delay_chain <= {
                                delay_chain[((i-1)*`DATA_WIDTH)-1:0], 
                                in_act_vec[(i*`DATA_WIDTH) +: `DATA_WIDTH]
                            };
                        end
                    end
                end
                
                // 输出寄存器链的最高位部分 (最老的数据)
                assign skewed_in_act_vec[(i*`DATA_WIDTH) +: `DATA_WIDTH] 
                     = delay_chain[((i)*`DATA_WIDTH)-1 -: `DATA_WIDTH];
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4. Instantiate Systolic Array (Connected to SKEWED inputs)
    // -------------------------------------------------------------------------
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] array_out_psum;

    systolic_array u_array (
        .clk            (clk),
        .rst_n          (rst_n),
        .en_compute     (ctrl_input_stream_en), // 注意：阵列内部应该持续使能，这里简化处理
        .row_load_en    (row_load_en),
        .in_act_vec     (skewed_in_act_vec),     // <--- 连接修复后的信号
        .in_weight_vec  (in_weight_vec),
        .out_psum_vec   (array_out_psum)
    );

    // -------------------------------------------------------------------------
    // 5. Glue Logic: Latency Compensation
    // -------------------------------------------------------------------------
    // 阵列行延迟 = ARRAY_ROW (12).
    // Skew Buffer 对最后一行也引入了 11 周期延迟 + 1 周期计算 = 12 周期.
    // 所以，有效输出确实是在输入使能后的 12 个周期开始出现的。
    // 这里的 LATENCY = 12 依然成立。
    
    localparam LATENCY = `ARRAY_ROW + 1; // FIX: 从 12 改为 13
    reg [LATENCY-1:0] valid_delay_line;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_delay_line <= 0;
        else valid_delay_line <= {valid_delay_line[LATENCY-2:0], ctrl_input_stream_en};
    end

    wire acc_wr_en = valid_delay_line[LATENCY-1]; 

    // -------------------------------------------------------------------------
    // 6. Glue Logic: Address Generation
    // -------------------------------------------------------------------------
    reg [3:0] acc_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_addr <= 0;
        end else begin
            if (acc_wr_en) begin
                acc_addr <= acc_addr + 1;
            end else if (ap_idle) begin
                acc_addr <= 0; 
            end
        end
    end

    // 7. Instantiate Accumulator Bank
    accumulator_bank u_accum (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (acc_addr),
        .wr_en          (acc_wr_en),
        .acc_mode       (cfg_acc_mode),
        .in_psum_vec    (array_out_psum),
        .out_acc_vec    (out_acc_vec)
    );

endmodule