DeiT-Tiny FPGA Accelerator Roadmap

Project: End-to-End Vision Transformer on Zynq-7020

Role: Principal FPGA Architect & Research Intern

Status: Phase 3 (Compute Core Verified)

📅 Phase 1: System Architecture Design (Completed)

[x] Feasibility Analysis: Confirmed DSP (12x16 Array) & BRAM usage.

[x] HW/SW Partitioning:

PL: GEMM, Accumulation, Quantization.

PS: Softmax, LayerNorm, GELU.

[x] Dataflow Strategy: Weight Stationary + Output Stationary Accumulation.

🛠 Phase 2 & 3: PL (Hardware) Implementation

1. Compute Subsystem (The "Heart")

[x] Global Parameters (params.vh): Defined physical dimensions (12x16) and bit widths.

[x] Processing Element (pe.v):

[x] Weight latching logic.

[x] INT8 MAC operation with DSP inference.

[x] Systolic data passing.

[x] Verification: pe_tb.v passed.

[x] Systolic Array (systolic_array.v):

[x] 2D Grid generation.

[x] Broadcast & Skew logic (handled by TB currently).

[x] Verification: systolic_array_tb.v passed (Numeric check).

[x] Global Controller (global_controller.v):

[x] FSM for Load/Compute/Drain states.

[x] Verification: global_controller_tb.v passed.

2. Memory & Post-Processing Subsystem (The "Limbs" - NEXT STEP)

此部分负责解决数据“进得来”和“出得去”的问题，是性能的关键。

[ ] Accumulator Bank (accumulator.v):

Function: 处理分块计算产生的 Partial Sum 累加 ($C_{tile} += A \times B$).

Challenge: Read-Modify-Write 时序匹配，支持 BRAM 读写。

[ ] Post-Processing Unit (ppu.v):

Function: Quantization (INT32 -> INT8), Bias Addition.

Challenge: 高效实现 Scaling (Multiplier + Shift) 替代除法。

[ ] On-chip Buffers (BRAM Wrappers):

[ ] input_buffer: Ping-Pong double buffering mechanism.

[ ] weight_buffer: Linear loading logic.

[ ] output_buffer: Collecting results for DMA.

3. Top-Level Integration

[ ] Accelerator Top (deit_accelerator_top.v):

Connecting Controller, Array, Accumulator, and Buffers.

[ ] AXI Interface Wrappers:

[ ] AXI-Lite (Control & Config).

[ ] AXI-Stream (Data mover).

🔍 Phase 4: System Verification (Simulation)

[ ] Full-System Testbench:

Simulating AXI transactions.

End-to-end matrix multiplication check with Python Golden Vectors.

🚀 Phase 5: Implementation & Deployment (On-Board)

[ ] Vivado Block Design: Zynq PS + DMA + Accelerator IP.

[ ] Synthesis & Implementation: Timing Closure (Target: 100MHz).

[ ] PYNQ Driver (Python):

Memory allocation (CMA).

Driver class for hardware control.

Integration with DeiT PyTorch/ONNX model.

📝 Architect's Notes (Current Focus)

Current Milestone: The Systolic Array is functionally correct.
Immediate Blocker: The array outputs raw 32-bit partial sums. We cannot send these back to DRAM directly (bandwidth too high).
Next Action: Design the Accumulator Bank to merge partial sums on-chip.