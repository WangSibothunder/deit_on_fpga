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

## 局部数据流动
- AXI-Lite 配置进入 deit_core、PPU 与各 Buffer 控制器。
- AXI-Stream Input 进入 input_buffer_ctrl，Weight 进入 weight_buffer_ctrl。
- deit_core 产生权重加载、输入流使能与 drain 控制。
- systolic_array 产生 psum，经 accumulator_bank 与 ppu 量化。
- output_buffer_ctrl 将 128b 结果拆分为 64b AXI-Stream 输出。
- 全局调试信号在 top 汇聚，便于 PS 侧观察。
