Weight Buffer Controller Specification

Version: 1.0
Date: 2026-01-16
Module: weight_buffer_ctrl.v
Status: Design Phase

1. 模块概述 (Overview)

weight_buffer_ctrl 用于管理脉动阵列的权重加载。由于我们采用 Weight Stationary (WS) 架构，权重需要在计算开始前被预加载到阵列的每一个 PE 中。

核心特性

2-to-1 Gearbox: 将 64-bit AXI-Stream 输入转换为 128-bit 内部存储位宽。每 2 个 DMA 周期对应 1 个阵列行加载周期。

Double Buffering (Ping-Pong): 尽管目前的 FSM 是串行的（Load -> Compute），但我们依然保留双缓冲架构，以支持未来的流水线优化（即在计算 Tile N 的同时加载 Tile N+1 的权重）。

LUTRAM Implementation: 由于每个 Tile 仅需存储 12 行权重（12 $\times$ 128-bit = 1.5Kb），我们使用 FPGA 的分布式 RAM (LUTRAM) 实现，节省 BRAM 资源。

2. 接口定义

Signal

Width

Dir

Description

AXI-Stream Slave







s_axis_tdata

64

In

Weights from DMA

s_axis_tvalid

1

In



s_axis_tready

1

Out

Always 1 (Flow control simplified)

Core Interface







i_weight_load_en

1

In

来自 Core 的读取请求 (对应 ctrl_weight_load_en)

o_weight_vec

128

Out

16 Cols * 8-bit weights

Control







i_bank_swap

1

In

Toggle Ping-Pong buffer

3. 地址与数据流

Input Sequence: 假设 12 行 (Row 0 to 11)。

DMA Order:

Word 0: Row 0 [63:0]

Word 1: Row 0 [127:64] -> Write RAM Addr 0

Word 2: Row 1 [63:0]

Word 3: Row 1 [127:64] -> Write RAM Addr 1

...

Core Load:

global_controller 拉高 load_en。

Buffer 每个时钟周期输出一行数据 (128-bit)，地址自增。