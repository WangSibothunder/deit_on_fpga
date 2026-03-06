Phase 1: System Architecture Design & Feasibility Analysis

Author: Principal FPGA Architect & Research Intern

Target Device: Xilinx Zynq-7020 (CLG400)

Model: DeiT-Tiny (Vision Transformer, ~5M Params)

Strategy: Hardware-Software Co-design with PYNQ Framework

1. Feasibility Analysis (The "Reality Check")

在写任何 Verilog 之前，我们必须算账。这是架构师最重要的素质。

1.1 算力资源分析 (DSP Constraints)

Target: 16x16 Systolic Array (256 PEs).

Zynq-7020 Resources: 220 DSP48E1 Slices.

Constraint Violation: \(256 > 220\)。

Architect's Note: 在 Zynq-7020 上实现物理上的 16x16 全 DSP 阵列是不可能的。

Solution: 我们将架构设计为 Parameterizable (参数化) 的 \(R \times C\) 阵列。

Recommendation: 推荐物理实现规模为 12x16 (192 DSPs) 或 14x14 (196 DSPs)。这能留下约 20-30 个 DSP 用于地址生成计算或其他逻辑，同时保持较高的利用率。

注: 为了教学方便，本文档后续逻辑逻辑将沿用你提出的 "16x16" 概念，但在实际 Parameter 定义时，我们将使用 ROW=12, COL=16。

1.2 存储资源分析 (Memory Hierarchy)

Model Size: DeiT-Tiny (INT8) $\approx 5 \text{MB}$ Weights.

On-chip BRAM: 4.9 Mb \(\approx 600 \text{KB}\)。

Conclusion: BRAM 无法存下整个模型。

Strategy:

Weights: 必须存储在片外 DDR3 中，通过 DMA 动态分块加载 (Tiling)。

Activation: Patch Embeddings 和中间特征图（Feature Maps）也需要分块。

Buffers: 我们需要设计 Ping-Pong Buffers 来掩盖 DMA 传输延迟。

1.3 带宽分析 (Bandwidth)

Interface: AXI HP (High Performance) Port (64-bit @ 100MHz = 800MB/s theoretical).

Systolic Demand: 假设 100MHz，16x16 阵列，若每周期都需加载新数据，带宽需求巨大。

Optimization: 必须利用 Data Reuse (数据复用)。K-Stationary (Output Stationary) 策略能最大化 Partial Sum 的复用，减少对带宽的压力。

2. System Architecture (软硬件划分)

我们将采用经典的 Overlay Architecture。

2.1 Hardware / Software Partitioning

|Module|Location|Reason|
|------|--------|------|
|MatMul (GEMM)|PL (FPGA)|计算密集型，占据 Transformer 95% 以上算力。适合脉动阵列。|
|Bias Add / Scaling|PL (FPGA)|流水线操作，紧跟 GEMM 输出处理。|
|Quant/De-quant|PL (FPGA)|简单的移位和截断操作，硬件效率极高。|
|Softmax|PS (ARM)|指数与除法在 FPGA 上消耗 LUT 巨大且精度难控，ARM 处理更灵活。|
|GELU / LayerNorm|PS (ARM)|非线性强，且数据量相对较小（相对于 GEMM 的计算量），由 CPU 处理。|
|Control Flow|PS (Python)|使用 PYNQ 控制层调度每一层的执行，简化 FPGA 状态机复杂度。|

2.2 Top-Level Block Diagram

+---------------------------------------------------------+
|                Zynq-7020 Processing System (PS)         |
|  [Python/Jupyter] -> [PYNQ Drivers] -> [DDR3 Memory]    |
+---------------------------+-----------------------------+
                            | AXI-Stream (DMA)
                            v
+---------------------------------------------------------+
|                  Programmable Logic (PL)                |
|                                                         |
|  +----------------+      +--------------------------+   |
|  |  AXI DMA Controller (S2MM / MM2S)                |   |
|  +-------+--------+------+------------+-------------+   |
|          | Weights       | Inputs     | Outputs         |
|          v               v            ^                 |
|  +-------+-------+  +----+---+   +----+-----------+     |
|  | Weight Buffer |  | In Buf |   | Out Buffer     |     |
|  | (Double Buf)  |  | (Ping) |   | (Accumulator)  |     |
|  +-------+-------+  +----+---+   +----+-----------+     |
|          |               |            |                 |
|          v               v            ^                 |
|  +--------------------------------------------------+   |
|  |           Systolic Array Controller              |   |
|  +--------------------------------------------------+   |
|  |                                                  |   |
|  |   16x16 (Logical) / 12x16 (Physical) Array       |   |
|  |   Dataflow: Output Stationary (K-Stationary)     |   |
|  |                                                  |   |
|  +--------------------------------------------------+   |
|                                                         |
+---------------------------------------------------------+


3. Core Micro-Architecture: The Systolic Array

这是本项目的灵魂。你提到的 "K-Stationary" 在脉动阵列术语中通常对应 Output Stationary (OS)，即部分和（Partial Sum）固定在 PE 中累加，直到计算完 K 维度。

3.1 Why Output Stationary (OS)?

在 Transformer 中，矩阵乘法通常是 \(A \times B\)。

Weights (B): 从顶部流入。

Inputs (A): 从左侧流入。

Partial Sums (C): 驻留在 PE 的寄存器中进行累加。

优势: 最大化了累加器的复用，减少了输出带宽需求（只需在该 Tile 计算完成后输出一次结果）。

3.2 Processing Element (PE) Design

我们需要设计一个极简的 PE 以节省资源。

Inputs: in_a (8-bit), in_b (8-bit), control_signals

Outputs: out_a (passed to right), out_b (passed to bottom), result (streamed out at end)

Internal: accumulator (24-bit or 32-bit to prevent overflow during K-loop).

Logic:

```verilog
always @(posedge clk) begin
    if (en) begin
        // DSP48E1 inferred MAC
        acc <= acc + (in_a * in_b); 
        // Systolic flow
        out_a <= in_a;
        out_b <= in_b;
    end
end
```


3.3 Data Mapping Strategy (DeiT Specific)

Transformer 的 Attention 机制包含 $Q, K, V$ 投影。

Matrix Dimensions: \((B, N, D)\). 

Tiling: 我们不能一次算完。我们需要将大矩阵切分为 \(12 \times 16\) 的小块 (Tiles)。

Schedule:

PS 端将权重块 \(W_{tile}\) 和输入块 \(X_{tile}\) 搬运到 PL 的 BRAM。

PL 启动状态机，将数据推入阵列。

阵列计算 \(12 \times 16\) 的结果子块。

结果写回输出 Buffer，再通过 DMA 传回 PS。

4. Why PYNQ? (The Efficiency Multiplier)

你可能会问，为什么不用纯 C 代码跑 Bare-metal？

Debugging Visibility: PYNQ 允许你在 Jupyter Notebook 中直接读取 FPGA 的寄存器（通过 AXI-Lite）。如果阵列卡死，你可以用 Python 脚本瞬间查看状态机的 State，而不是重新编译 ILA (Integrated Logic Analyzer)。

Data Handling: Python 的 numpy 处理图像数据预处理和后处理（DeiT 的 Image Patching）极其高效。

Driver Simplicity: 我们不需要写复杂的 Linux Kernel Driver。pynq.Overlay 和 pynq.lib.dma 已经帮我们封装好了底层驱动。

Agile Iteration: 我们的重点是 FPGA 加速器的 RTL 设计，而不是嵌入式软件栈的搭建。

5. Next Steps (Action Plan)

为了进入 Phase 2: Module Specification，请你完成以下思考题，并在回复中确认：

Bit Width: 累加器（Accumulator）应该选 24-bit 还是 32-bit？考虑到 INT8 乘法最大值为 \(127 \times 127 \approx 16000\)，DeiT 的 Hidden Dimension 约为 192，累加会不会溢出？

Unpacking: DDR 中的数据通常是 64-bit 宽（AXI HP）。如何将这 64-bit 拆解并分发给 12 行（或 16 行）的阵列？我们需要一个什么样的转换模块？

Waiting for your confirmation to proceed to Spec definition.