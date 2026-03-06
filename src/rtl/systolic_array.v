// -----------------------------------------------------------------------------
// 文件名: systolic_array.v
// 描述: 参数化脉动阵列顶层
// 架构: 
//    - Row: `ARRAY_ROW` (12)
//    - Col: `ARRAY_COL` (16)
//    - Dataflow: Weight Stationary
//    - Input: Left -> Right (Activations)
//    - Output: Top -> Down (Partial Sums)
// -----------------------------------------------------------------------------
`include "params.vh"


module systolic_array (
    input  wire                         clk,
    input  wire                         rst_n,

    // --- 控制信号 ---
    input  wire                         en_compute, // 全局计算使能
    // 权重加载使能：每一位控制对应的一行 (One-Hot or Sequential logic outside)
    // 例如: row_load_en[0] = 1 时，第0行加载权重
    input  wire [`ARRAY_ROW-1:0]        row_load_en, 

    // --- 数据通路 (扁平化端口) ---
    // 输入特征向量 (12行 x 8bit) -> 这里的输入是同时喂给左侧第一列的
    input  wire [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec,
    
    // 权重向量 (16列 x 8bit) -> 用于加载阶段，广播给该列所有行
    input  wire [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec,

    // 输出部分和向量 (16列 x 32bit) -> 从最底下一行流出
    output wire [`ARRAY_COL*`ACC_WIDTH-1:0]   out_psum_vec
);

    // -------------------------------------------------------------------------
    // 内部连线定义 (Wires)
    // -------------------------------------------------------------------------
    // 定义二维网格连线。我们需要 [ROW][COL] 的结构，但 Verilog 只能声明 1D arrays of wires
    // 这里我们用 generate block 里的隐式连线或者声明多个 wire
    
    // Horizontal connections: act passing [Row][Col+1]
    // act_wires[r][c] 表示第 r 行，第 c 列 PE 的输出 act
    wire [`DATA_WIDTH-1:0] act_wires [`ARRAY_ROW-1:0][`ARRAY_COL-1:0];

    // Vertical connections: psum passing [Row+1][Col]
    // psum_wires[r][c] 表示第 r 行，第 c 列 PE 的输出 psum
    wire [`ACC_WIDTH-1:0]  psum_wires [`ARRAY_ROW-1:0][`ARRAY_COL-1:0];

    // -------------------------------------------------------------------------
    // 生成矩阵 (Generate Grid)
    // -------------------------------------------------------------------------
    genvar r, c;
    generate
        for (r = 0; r < `ARRAY_ROW; r = r + 1) begin : ROW_LOOP
            for (c = 0; c < `ARRAY_COL; c = c + 1) begin : COL_LOOP
                
                // --- 1. 准备输入信号 ---
                
                // (A) Activation Input (Left -> Right)
                wire [`DATA_WIDTH-1:0] pe_in_act;
                if (c == 0) begin
                    // 第一列：来自全局输入向量
                    // 拆包: in_act_vec [r*8 +: 8]
                    assign pe_in_act = in_act_vec[(r * `DATA_WIDTH) +: `DATA_WIDTH];
                end else begin
                    // 其他列：来自左侧 PE 的输出
                    assign pe_in_act = act_wires[r][c-1];
                end

                // (B) Partial Sum Input (Top -> Down)
                wire [`ACC_WIDTH-1:0] pe_in_psum;
                if (r == 0) begin
                    // 第一行：输入为 0 (累加的起始点)
                    assign pe_in_psum = {`ACC_WIDTH{1'b0}};
                end else begin
                    // 其他行：来自上方 PE 的输出
                    assign pe_in_psum = psum_wires[r-1][c];
                end

                // (C) Weight Input (Broadcast per Column)
                // 每一列共享同一个权重输入端口
                wire [`DATA_WIDTH-1:0] pe_in_weight;
                assign pe_in_weight = in_weight_vec[(c * `DATA_WIDTH) +: `DATA_WIDTH];

                // (D) Load Enable (Broadcast per Row)
                // 每一行共享同一个加载使能信号
                wire pe_load_en;
                assign pe_load_en = row_load_en[r];

                // --- 2. 实例化 PE ---
                pe pe_inst (
                    .clk            (clk),
                    .rst_n          (rst_n),
                    .en_compute     (en_compute),
                    .load_weight    (pe_load_en),
                    
                    .in_act         (pe_in_act),
                    .in_weight      (pe_in_weight),
                    .in_psum        (pe_in_psum),
                    
                    .out_act        (act_wires[r][c]),   // 连接到水平输出线
                    .out_psum       (psum_wires[r][c])   // 连接到垂直输出线
                );

                // --- 3. 处理最后一行的输出 ---
                if (r == `ARRAY_ROW - 1) begin
                    // 将最后一行的 psum 连接到模块总输出
                    assign out_psum_vec[(c * `ACC_WIDTH) +: `ACC_WIDTH] = psum_wires[r][c];
                end

            end // End COL
        end // End ROW
    endgenerate

endmodule