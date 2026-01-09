Phase 2: Complete Module Specification (The "Missing Pieces")

Scope: Full PL Design for Weight Stationary (WS) Systolic Array
Top Module: DeiT_Accelerator_Top

1. Top-Level Hierarchy & Dataflow Recap

在 Weight Stationary (WS) 架构中，数据流的协调是核心挑战。

Setup Phase: 权重通过 Weight_Loader 加载进阵列并锁定。

Compute Phase: 输入 $A$ 从 Input_Buffer 读取，广播进阵列各行；部分和（Partial Sums）向下流动。

Drain Phase: 最终结果流出到底部 Accumulator，经 PPU 处理后存入 Output_Buffer，等待 DMA 取走。

2. Module 4: Global_Controller (The Brain)

Function: 整个加速器的指挥官。负责协调 DMA 握手、Buffer 读写切换（Ping-Pong）、阵列启动以及中断生成。它通过 AXI-Lite 接口接收来自 PS 端 Python 驱动的指令。

2.1 Register Map (AXI-Lite Slave)

| Offset | Name | Type | Width | Description |
|--------|------|------|-------|-------------|
| 0x00 | CTRL_REG | RW | 32 | [0]: Start, [1]: Reset_Soft, [2]: Interrupt_En |
| 0x04 | STATUS_REG | RO | 32 | [0]: Idle, [1]: Busy, [2]: Done, [3]: Err |
| 0x08 | MATRIX_M | RW | 32 | Matrix A rows (e.g., Sequence Length, 196) |
| 0x0C | MATRIX_K | RW | 32 | Common dimension (Input Channels, 192) |
| 0x10 | MATRIX_N | RW | 32 | Matrix B cols (Output Channels, 192) |
| 0x14 | TILE_COUNT | RW | 32 | Total number of tiles to process |

2.2 Finite State Machine (FSM)

这是一个嵌套循环的控制器。

Outer Loop: 遍历 Tiles (分块)。

Inner Loop: 控制当前 Tile 的 K 维度累加。

States:

IDLE: 等待 CTRL_REG[0] == 1。

LOAD_W_REQ: 向 Weight_Buffer 发出加载请求，等待权重就绪。

LOAD_W_EXEC: 驱动阵列进入 LOAD 模式，将权重移入 PE。

COMPUTE_STREAM:

启动 Input_Buffer 读地址计数器。

同时启动 Accumulator 读/写。

计数 K 周期。

DRAIN: 等待流水线排空（Pipeline Flush）。

WRITE_BACK: 通知 Output_Buffer 数据已准备好，触发 DMA 发送。

DONE: 触发中断，回到 IDLE。

3. Module 5: Input_Buffer_Ctrl (The Feeder)

Function: 解决带宽不匹配问题。

Input (Write): AXI-Stream (64-bit width from DMA).

Output (Read): Array Input Vector ($R \times 8$-bit).

Mechanism: Double Buffering (Ping-Pong)。当阵列计算 Buffer A 时，DMA 正在填充 Buffer B。

3.1 Memory Organization

为了在一个周期内给阵列的 $R$ 行（例如 12 行）同时提供数据，我们需要将 BRAM 组织为 Wide Word 模式，或者使用 Banked 架构。

Design Choice: 使用一个位宽为 $R \times 8$ bit 的逻辑 RAM。

Conversion: 输入侧需要一个 S2P (Serial-to-Parallel) 逻辑，将 DMA 的 64-bit 数据拼凑成 $(R \times 8)$-bit 宽的字，写入 RAM。

Interface

| Signal | Width | Description |
|--------|-------|-------------|
| **AXIS (Write)** | | |
| s_axis_tdata | 64 | Data from DMA |
| s_axis_tvalid | 1 | Handshake |
| s_axis_tready | 1 | Handshake |
| **Array (Read)** | | |
| array_in_vec | $R \times 8$ | Broadcast inputs for all rows |
| rd_en | 1 | From Global Controller |
| **Control** | | |
| bank_swap | 1 | Toggle Ping/Pong |

Logic Highlight (Unpacking):
如果 $R=12$ (12行)，我们需要 $12 \times 8 = 96$ bits。
DMA 每次送 64 bits。我们需要一个小的 FIFO 或 Shift Register 来攒够 96 bits，然后写一次 BRAM。
Architect Note: 这是 RTL 实现中最繁琐的部分，建议使用 Xilinx FIFO Generator 配置为 "Independent Clocks / Different Aspect Ratios"，Write Width 64, Read Width 96 (如果 IP 支持) 或手动编写移位逻辑。

4. Module 6: Weight_Buffer_Ctrl (The Loader)

Function: 管理权重的加载。
在 Weight Stationary 架构中，权重加载不需要像输入那样频繁（Ping-Pong 需求较低），但必须支持 Shift Chain 加载模式。

Mechanism:

从 DMA 接收权重数据。

阵列的每一列（Column）可以被看作一个长的移位寄存器（Shift Register）。

Weight_Buffer_Ctrl 将数据串行地推入每一列的底部，数据像贪吃蛇一样向上移动，直到填满该列。

为了速度，我们可以 并行加载所有列。

Interface

| Signal | Width | Description |
|--------|-------|-------------|
| **AXIS (Write)** | | |
| s_axis_w_tdata | 64 | Weight stream |
| **Array (Feed)** | | |
| w_feed_vec | $C \times 8$ | 1 byte per column |
| **Control** | | |
| w_load_en | 1 | Tells PEs to shift weights in |

5. Module 7: Output_Buffer_Ctrl (The Collector)

Function: 缓冲 PPU 处理后的 INT8 结果，并打包传回 DMA。
Mechanism: 同样建议使用 Ping-Pong 或大容量 FIFO。

Input: 来自 PPU 的 8-bit 结果流（可能是 $C$ 个并行数据，或者串行化后的数据）。

Packing: 我们通常需要将 8-bit 结果打包成 64-bit 再次通过 AXIS 发送给 PS。

Logic:

接收 $8 \times 8$-bit data = 64-bit。

Assert m_axis_tvalid。

6. System Integration Diagram (RTL View)

现在我们可以画出完整的连线图（这直接对应你的 top module Verilog 代码）：

                                +----------------------+
                                |   AXI-Lite Config    |
                                +----------+-----------+
                                           |
                                           v
                             +-------------+------------+
                             |   Global_Controller      |
                             |  (FSM, Regs, Counters)   |
                             +--+-------+--------+------+
                                |       |        |
             (Controls Input)   |       |        | (Controls Weight)
             +------------------+       |        +------------------+
             |                          |                           |
             v                          v                           v
+------------+------+        +----------+-----------+        +------+-------------+
| Input_Buffer_Ctrl |        |    Accumulator_Ctrl  |        | Weight_Buffer_Ctrl |
| (S2P, Ping-Pong)  |        |    (BRAM Bank)       |        | (Column Loader)    |
+---+---------------+        +----------+-----------+        +------+-------------+
    |                                   ^                           |
    | (Array Inputs: R x 8b)            | (Psums: C x 32b)          | (Weights: C x 8b)
    |                                   |                           |
    |        +--------------------------+------------------+        |
    |        |                                             |        |
    +------->+          Systolic_Array_Top                 +<-------+
             |          (R x C PEs)                        |
             |                                             |
             +---------------------------------------------+

             (Accumulated Psums go to PPU logic inside Accumulator Wrapper)
                                        |
                                        v
                             +----------+-----------+
                             | Output_Buffer_Ctrl   |
                             | (P2S, FIFO to DMA)   |
                             +----------------------+


7. Critical Implementation Details (Pre-RTL Checklist)

在开始写代码前，请确认以下细节：

Block RAM Usage Estimation:

Input Buffer: $12 \text{ (rows)} \times 192 \text{ (max K)} \times 8\text{bit} \times 2 \text{ (PingPong)} \approx 36 \text{Kb}$ (1 BRAM tile). OK.

Weight Buffer: 取决于 Tile Size。$12 \times 16 \times 8\text{bit} \approx 1.5 \text{Kb}$ (Distributed RAM / LUTRAM 即可，无需 BRAM). OK.

Accumulator Buffer: $16 \text{ (cols)} \times 12 \text{ (rows)} \times 32\text{bit} \approx 6 \text{Kb}$. OK.

结论： Zynq-7020 BRAM 资源非常充足，放心使用。

Clock Domain Crossing (CDC):

DMA (AXI HP) 可能运行在 100MHz 或 150MHz。

Core Array 运行在多少？建议与 DMA 同频（System Clock），避免复杂的跨时钟域处理。我们将系统统一跑在 100MHz。