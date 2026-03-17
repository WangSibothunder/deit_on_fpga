# DeiT Accelerator Top 规格书

Version: 1.0
Date: 2026-03-08
Module: deit_accelerator_top.v
Status: 新增文档

## 1. 模块概述
顶层封装模块，连接 AXI-Lite 控制、AXI-Stream 数据通道与内部 Core/Buffer/PPU/Output Buffer。

## 2. 接口定义
### 2.1 AXI-Lite
标准 s_axi_* 控制接口。

### 2.2 AXI-Stream
| 信号 | 方向 | 说明 |
| --- | --- | --- |
| axis_in_* | In | 输入/权重共享通道 |
| axis_out_* | Out | 量化输出通道 |

## 3. 时序/延迟
- AXI-Stream In 通过 core_weight_dma_req 分流给输入缓冲或权重缓冲。
- Input Bank Swap 在 ap_start 上升沿触发。
- Weight Bank Swap 在 DMA 请求下降沿触发。

## 4. 关键设计机制
- 软复位: sys_rst_n = rst_n & ctrl_soft_rst_n。
- PPU 输出受 cfg_output_en 控制。
- 输出缓冲提供 128->64 Gearbox 与帧内 last 生成。

## 5. 调试信号
- dbg_reg0~dbg_reg3 打包多个内部状态信号。
