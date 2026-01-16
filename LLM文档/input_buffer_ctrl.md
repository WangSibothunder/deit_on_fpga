Input Buffer Controller Specification

Version: 1.1 (Pipeline Fix Applied)
Date: 2026-01-16
Module: input_buffer_ctrl.v
Status: Verified (All Checkpoints Passed)

1. 模块概述 (Overview)

input_buffer_ctrl 是 PL Overlay 数据通路的第一站。它的主要职责是解决 带宽不匹配 和 数据格式不匹配 的问题，充当 DMA 与脉动阵列之间的“变速箱”和“蓄水池”。

核心功能

Gearbox (S2P Conversion): 将 DMA 的 64-bit AXI-Stream 数据流实时转换为脉动阵列所需的 96-bit ($12 \times 8$-bit) 并行向量。

Ping-Pong Buffering: 采用双缓冲机制，允许在 Core 计算当前 Tile (Read Bank A) 的同时，DMA 预加载下一个 Tile (Write Bank B)，从而掩盖数据传输延迟。

Pipeline Alignment: 实现了写地址流水线打拍，确保 RAM 的写使能与地址严格对齐，防止首数据写入错误地址。

2. 接口定义 (Interface Definition)

Signal Group

Name

Width

Direction

Description

Global

clk

1

In

System Clock (100MHz)



rst_n

1

In

Active Low Reset

AXI-Stream Slave

s_axis_tdata

64

In

来自 DMA 的原始数据流

(Write Port)

s_axis_tvalid

1

In

数据有效指示



s_axis_tready

1

Out

总是为 1 (假设 buffer 不会溢出)



s_axis_tlast

1

In

(当前版本未使用，预留)

Core Interface

i_rd_en

1

In

核心读取请求 (Read Enable)

(Read Port)

o_array_vec

96

Out

输出给阵列的向量 (12 rows * 8 bit)

Control

i_bank_swap

1

In

Toggle Signal. 切换 Ping-Pong 状态。



每当完成一个 Tile 的计算/加载后由 Controller 触发。

3. 关键设计机制 (Key Design Mechanisms)

3.1 3-to-2 Gearbox 状态机

由于输入是 64-bit，输出是 96-bit，最小公倍数为 192 bits。
这意味着 每 3 个 64-bit 输入周期，产生 2 个 96-bit 输出周期。

State 0 (Word 1): 接收 64-bit，暂存至 temp_reg。无写入。

State 1 (Word 2): 接收 64-bit。

Write 1: 拼接 {Current[31:0], temp_reg[63:0]} (Little Endian) -> 写入 RAM。

Store: 将 Current[63:32] 暂存至 temp_reg。

State 2 (Word 3): 接收 64-bit。

Write 2: 拼接 {Current[63:0], temp_reg[31:0]} -> 写入 RAM。

Reset: 回到 State 0。

3.2 地址流水线对齐 (Critical Fix)

在初始设计中，RAM 写使能 (ram_wen) 是在状态机内部逻辑产生的，相比状态跳转延迟了一拍。如果直接使用当前的写指针 (wr_ptr) 作为地址，会导致数据写入了 wr_ptr + 1 的位置。

解决方案: 引入 wr_addr_pipe 寄存器。

在状态机决定写入的 当拍 (T0)，将当前的 wr_ptr 锁存入 wr_addr_pipe。

在 RAM 执行写入的 下一拍 (T1)，使用 wr_addr_pipe 作为地址。

效果: ram_wen (at T1) 与 wr_addr_pipe (at T1 保持 T0 的值) 完美对齐。

3.3 Ping-Pong 内存管理

使用单块双倍深度的 BRAM 模拟双缓冲。

Memory Size: Width 96, Depth 512 (256 per Bank).

Bank Select: bank_sel 寄存器。

Write Address: {bank_sel, wr_addr_pipe}

Read Address: {~bank_sel, rd_ptr}

Swap: i_bank_swap 信号翻转 bank_sel，并同时复位读写指针。

4. 验证结果 (Verification Results)

Testbench: src/input_buffer_ctrl_tb.v

Checkpoints:

[PASS] CP1: Gearbox Logic. 验证了 3个 64-bit 单词被正确重组为 2个 96-bit 向量。

[PASS] CP2: Read Verification. 验证了 Bank 0 写入的数据能被正确读出，且无错位。

[PASS] CP3: Ping-Pong Safety. 验证了在读取 Bank 0 时，写入 Bank 1 不会破坏 Bank 0 的数据。

5. 资源预估 (Resource Estimation)

BRAM: 1 Tile (36Kb) Configured as 512x72 (Simple Dual Port) + LUTRAM expansion for 96-bit width (or 2 BRAMs in parallel).

Zynq-7020 BRAMs are 36Kb blocks.

实际综合时，Vivado 可能会使用 3 个 18k BRAM 并联来实现 96-bit 位宽。

LUTs: < 100 (State machine & Muxes).