Phase 2: Module Specification (Weight Stationary Design)

Architecture: Weight Stationary (WS) Systolic Array

Quantization: INT8 Symmetric / Asymmetric

Platform: Zynq-7020

1. Mathematical Formulation & Tiling Strategy

为了在有限的 \(R \times C\) 阵列上计算巨大的矩阵乘法 \(A \times B = C\)，我们必须进行分块（Tiling）。

1.1 符号定义

Matrix A (Input): shape \((M, K)\)

Matrix B (Weights): shape \((K, N)\)

Matrix C (Output): shape \((M, N)\)

Hardware Array: \(R\) rows, \(C\) columns (Physical: \(12 \times 16\))

1.2 分块计算证明 (Block-wise Proof)

我们将矩阵切分为大小为 \(TILE\_M \times TILE\_K\) 和 \(TILE\_K \times TILE\_N\) 的小块。
由于是 Weight Stationary，我们将权重矩阵 \(B\) 的一个子块 \(B_{sub}\) (\(K \times C\)) 加载进阵列。但由于硬件行数只有 \(R\)，我们通常一次只能加载 \(R \times C\) 的权重。

实际映射流程 (WS Dataflow):

Weight Loading: 加载 \(B\) 的一个 \(R \times C\) 子块到 PEs 中。每个 PE 存储一个权重 \(W_{r,c}\)。

Input Streaming: 输入矩阵 \(A\) 的对应列流过阵列。

\(A\) 的数据 \(a_{i,k}\) 必须被 Broadcast (广播) 到同一行的所有 PE，或者在 WS 脉动中，输入从左侧进入，向右传递。

Partial Sum Flow: 在 WS 模式下，部分和 (Partial Sums) 通常垂直向下流动。

\(Psum_{i,j} = Psum_{i-1,j} + A_{i, k} \times W_{k, j}\) (此公式视具体 PE 实现而定，WS 通常意味着 Weight 固定，Input 广播/脉动，Output 垂直累加)。

分块合并 (Accumulation Strategy):
由于 \(K\) (Input Channel) 维度通常远大于阵列的维度，我们必须在时间上累加。


\[C_{m,n} = \sum_{k=0}^{K-1} A_{m,k} \cdot B_{k,n}\]


分解为 Tile：


\[C_{tile} = \sum_{t=0}^{T-1} (A_{tile\_t} \times B_{tile\_t})\]


这里的 \(\sum\) 就是 Accumulator 要做的工作。

2. Hardware Architecture Diagram

       +-------------------+
       |   AXI DMA (PS)    |
       +---------+---------+
                 |
         (AXI-Stream 64-bit)
                 v
+----------------+----------------+
|  Global System Controller (FSM) | <--- Controls Tiling & Modes
+----------------+----------------+
                 |
+----------------v----------------+     +-----------------------+
|   Input Buffer (Ping-Pong)      |     |  Weight Buffer (SRAM) |
|   (Conversion: 64b -> Array)    |     |  (Loads into PEs)     |
+----------------+----------------+     +-----------+-----------+
                 | (Broadcasting rows)              | (Pre-load)
                 v                                  v
+---------------------------------------------------+
|            Weight Stationary Systolic Array       |
|            Size: 12 (Rows) x 16 (Cols)            |
|                                                   |
|   [PE] [PE] ... [PE]  <-- Row 0 (Weight Tile 0)   |
|    |    |        |                                |
|    v    v        v  (Partial Sums flow down)      |
|   [PE] [PE] ... [PE]  <-- Row 1                   |
|    |    |        |                                |
+---------------------------------------------------+
                 | 32-bit Partial Sums per Col
                 v
+---------------------------------------------------+
|           Accumulator Bank (Adders + SRAM)        |
|  *CRITICAL*: Merges partial sums from K-loop      |
|  Psum_New = Psum_Old + Array_Output               |
+---------------------------------------------------+
                 | 32-bit Accumulated Results
                 v
+---------------------------------------------------+
|           Post-Processing Unit (PPU)              |
|  1. Bias Addition (Broadcast)                     |
|  2. Re-Quantization (Scale, Shift, Clip)          |
+---------------------------------------------------+
                 | 8-bit Final Result
                 v
+---------------------------------------------------+
|           Output Buffer -> DMA                    |
+---------------------------------------------------+


3. Detailed Module Specifications

3.1 Module: PE_WeightStationary

Function: 核心计算单元。

Mode 1 (Load): 接收权重并存储到内部寄存器 reg_w。

Mode 2 (Compute): 接收输入 in_act 和上方传来的 in_psum，计算并输出 out_psum 到下方。

|Signal Name|Width|Direction|Description|
|-----------|-----|---------|-----------|
|clk, rst_n|1|In|System clock & Active low reset|
|is_load_weight|1|In|Control signal to latch weight|
|in_weight|8|In|Weight value (used during load mode)|
|in_act|8|In|Activation input (Broadcasted or passed horizontally)|
|in_psum|32|In|Partial sum from PE above (0 for top row)|
|out_psum|32|Out|Result to PE below: in_psum + (in_act * reg_w)|

Timing/Logic:

always @(posedge clk) begin
    if (is_load_weight) 
        reg_w <= in_weight;
    else 
        out_psum <= in_psum + (in_act * reg_w); // DSP48 inferred
end


3.2 Module: Accumulator_Bank (The "Merger")

Function: 解决分块计算后的合并问题。这是 PL 端的关键组件。
由于阵列一次只能算 \(K\) 维度的一部分（比如 12），而 DeiT 的 \(K=192\)。我们需要循环 \(\lceil 192/12 \rceil = 16\) 次。
Accumulator_Bank 包含一块 BRAM，用于存储中间的 32-bit 累加值。

Logic:

If k_loop_index == 0: Write_Data = Array_Output (覆盖旧数据)

If k_loop_index > 0: Write_Data = Array_Output + Read_Data_From_BRAM (累加)

If k_loop_index == LAST: Enable Output to PPU.

3.3 Module: Post_Processing_Unit (Quantization)

Function: 将 32-bit 累加结果转回 8-bit。这是端到端推理精度的关键。
Math:
\[ X_{int8} = \text{Clamp} \left( \lfloor (X_{int32} + \text{Bias}) \times S_{scale} \gg S_{shift} \rfloor + Z_{point} \right) \]

Implementation Trick: 浮点乘法 \(S_{scale}\) 会被转换为定点整数乘法（Multiplier）和右移（Shift）。这些参数（Multiplier, Shift）由离线量化工具（如 PyTorch）计算好，通过 AXI-Lite 配置给 FPGA。

Signal Name

Width

Direction

Description

in_acc_data

32

In

From Accumulator Bank

cfg_bias

32

In

Bias value (loaded per channel)

cfg_mult

16

In

Quantization Multiplier (Fixed point)

cfg_shift

5

In

Right shift amount

cfg_zp

8

In

Output Zero Point

out_data

8

Out

Final INT8 result to DMA

Verilog Logic Snippet:

```verilog
// Stage 1: Add Bias
wire signed [31:0] val_biased = in_acc_data + cfg_bias;
// Stage 2: Scale (Fixed Point Multiply)
wire signed [47:0] val_scaled = val_biased * cfg_mult; 
// Stage 3: Shift
wire signed [31:0] val_shifted = val_scaled >>> cfg_shift;
// Stage 4: Add Zero Point & Clamp
wire signed [31:0] val_final = val_shifted + cfg_zp;
assign out_data = (val_final > 127) ? 127 : (val_final < -128) ? -128 : val_final[7:0];
```


4. Verification Plan (Phase 2 Requirement)

在写 RTL 之前，我们需要构建 Golden Vectors。
我建议你使用 Python 模拟这个分块过程，确保逻辑无误。

Generate Random Data: Create \(A (192, 192)\) and \(B (192, 192)\).

Software Emulation:

Slice \(A\) and \(B\) into \(12 \times 16\) tiles.

Simulate the "Accumulator Bank" behavior: Sum up the partial results of tiles.

Simulate the "PPU": Apply integer scaling and shifting.

Save: Save inputs and expected outputs to .txt files for Verilog Testbench.