AXI-Lite Control Interface Specification

Version: 1.0
Date: 2026-01-16
Module: axi_lite_control.v
Status: Verified (Checkpoints Passed)

1. 模块概述 (Overview)

本模块 (axi_lite_control) 是 PL 端的控制中心，作为 Zynq PS (Processing System) 与 FPGA 加速器核心 (deit_core) 之间的桥梁。它遵循 AMBA AXI4-Lite 协议，提供了一组内存映射寄存器（Memory-Mapped Registers），允许软件通过读写特定物理地址来控制硬件行为。

核心功能

参数配置：配置矩阵维度、计算模式等。

启动控制：提供带自动清除（Auto-Clear）功能的启动信号。

状态回读：提供带粘滞（Sticky Bit）功能的中断状态回读。

复位管理：提供软件控制的软复位功能。

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

系统时钟 (100MHz), 必须与 AXI 总线时钟同步



rst_n

1

In

系统复位 (Active Low)

AXI Slave

s_axi_aw*

-

In/Out

写地址通道 (Address, Valid, Ready)



s_axi_w*

-

In/Out

写数据通道 (Data, Strb, Valid, Ready)



s_axi_b*

-

Out/In

写响应通道 (Resp, Valid, Ready)



s_axi_ar*

-

In/Out

读地址通道 (Address, Valid, Ready)



s_axi_r*

-

Out/In

读数据通道 (Data, Resp, Valid, Ready)

To Core

o_ap_start

1

Out

Pulse. 启动核心计算。高电平持续 1 周期。



o_soft_rst_n

1

Out

Level. 软件复位信号。0: Reset, 1: Active.



o_cfg_compute_cycles

32

Out

Level. 配置 K 维度的计算步数 (Seq Len).



o_cfg_acc_mode

1

Out

Level. 累加模式。0: Overwrite, 1: Accumulate.

From Core

i_ap_done

1

In

Pulse. 核心计算完成信号。



i_ap_idle

1

In

Level. 核心空闲状态指示。

3. 寄存器映射 (Register Map)

Base Address: 分配于 Vivado Address Editor (例如 0x4000_0000)。
Data Width: 32-bit。
Endianness: Little Endian。

Offset

Name

Access

Bit

Description

0x00

CTRL_REG

RW

[0]

AP_START



写 1 启动加速器。硬件会自动产生一个脉冲并将此位清零。



(Software: Write 1 only)







[1]

SOFT_RST_N



0: 强制复位核心。



1: 释放复位，核心正常工作。



(Default: 0)







[31:2]

Reserved

0x04

STATUS_REG

RW

[0]

AP_DONE (Sticky)



硬件会在 ap_done 脉冲到来时将此位置 1。



软件必须写 1 清零 (W1C) 才能清除此状态。



(Read: 1=Done, Write: 1=Clear)







[1]

AP_IDLE



实时反映核心是否空闲。



1: Idle, 0: Busy.



(Read Only)







[31:2]

Reserved

0x08

CFG_K_DIM

RW

[31:0]

K Dimension / Sequence Length



设置输入序列的长度 (M)，即硬件需要运行的时钟周期数。



例如：对于 Patch Token，通常设为 197。

0x0C

CFG_ACC_MODE

RW

[0]

Accumulator Mode



0: Overwrite Mode. (用于 K 维度分块的第一个 Tile)



1: Accumulate Mode. (用于后续 Tile，将结果累加到之前的 Partial Sum 上)



(Default: 0)







[31:1]

Reserved

0x10

VERSION_REG

RO

[31:0]

Version ID



固定值 0x20260116。用于软件验证 Bitstream 版本。

4. 关键机制说明 (Key Mechanisms)

4.1 启动机制 (Auto-Clear)

为简化 Python 驱动，ap_start 实现了自清除逻辑：

Python 执行 mmio.write(0x00, 1)。

T0: 硬件寄存器 reg_ctrl[0] 变为 1。

T1: o_ap_start 输出高电平。

T2: 硬件逻辑检测到 o_ap_start 为高，自动将 reg_ctrl[0] 和 o_ap_start 强制复位为 0。

结果：产生一个标准的单周期脉冲，软件无需再写 0。

4.2 完成机制 (W1C & Sticky Bit)

由于硬件计算速度极快，Python 的轮询（Polling）可能会错过 ap_done 的瞬间脉冲。

Set: 当 Core 输出 i_ap_done 脉冲时，内部锁存器 reg_status[0] 变为 1 并保持。

Read: Python 读取 0x04，如果读到 1，说明任务已完成。

Clear: Python 处理完数据后，执行 mmio.write(0x04, 1)。

Result: reg_status[0] 变回 0，准备下一次任务。

4.3 跨时钟域 (CDC)

设计假设: AXI 总线时钟与核心计算时钟同源 (FCLK_CLK0 @ 100MHz)。

处理: 信号直接直连，无额外的 FIFO 或双触发器同步链。如果未来更改为异步时钟，需在此模块添加 CDC 处理。

5. 验证状态 (Verification Status)

Testbench: src/axi_lite_control_tb.v

Checkpoints:

[Pass] CP1: Version ID Read

[Pass] CP2: Read/Write Configuration Registers

[Pass] CP3: Soft Reset Control

[Pass] CP4: ap_start Pulse Generation & Auto-Clear (Verified with delay)

[Pass] CP5: ap_done Sticky Bit & Write-1-to-Clear