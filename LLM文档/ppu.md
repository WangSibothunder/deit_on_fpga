Post-Processing Unit (PPU) Specification

Version: 1.0
Date: 2026-01-16
Module: ppu.v
Status: Design Phase

1. 模块概述 (Overview)

PPU 负责将 Accumulator 输出的高精度 INT32 数据流，通过定点算术运算，压缩回 INT8 格式，以便存入 Output Buffer 并通过 DMA 传回内存。

核心功能

Scaling: 使用定点乘法模拟浮点缩放 ($Input \times M$). $M$ 是一个 16-bit 的定点整数。

Shifting: 右移操作以调整定点位置 ($Result \gg S$).

Zero-Point Add: 加上输出的零点 ($+ ZP$).

Clamping: 饱和截断到 [-128, 127] (INT8) 或 [0, 255] (UINT8).

2. 接口定义

Signal

Width

Dir

Description

Data Path







clk, rst_n

1

In

Clock & Reset

i_valid

1

In

Input Valid

i_data_vec

16*32

In

来自 Accumulator 的 16 个 INT32

o_valid

1

Out

Output Valid (Pipeline delay)

o_data_vec

16*8

Out

输出给 Output Buffer 的 16 个 INT8

Configuration





From AXI-Lite Control

cfg_mult

16

In

Quantized Multiplier (Fixed Point)

cfg_shift

5

In

Right Shift Amount

cfg_zp

8

In

Output Zero Point

3. 资源消耗预警 (DSP Usage)

我们需要并行处理 16 个数据。

每个通道需要 1 个乘法器。

Zynq-7020 总共 220 DSPs。Systolic Array 用了 $12 \times 16 = 192$ 个。

剩余 $220 - 192 = 28$ 个。

PPU 需要 16 个 DSP。资源是够的 (192 + 16 = 208 < 220)，但比较紧张。

备选方案：如果时序或布线困难，可以将 PPU 序列化（例如每周期处理 8 个，分两拍），但这会增加控制复杂度。目前先尝试全并行。