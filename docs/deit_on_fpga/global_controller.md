# Global Controller 规格书

Version: 1.0
Date: 2026-03-08
Module: global_controller.v
Status: 新增文档

## 1. 模块概述
global_controller 是全局控制 FSM，负责权重加载、输入流控制、排空 (drain) 以及完成/空闲标志生成。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| LATENCY | 28 | 排空周期（与流水线延迟相关） |

## 3. 接口定义
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| ap_start | 1 | In | 启动 |
| cfg_seq_len | 32 | In | 计算序列长度 |
| ap_done | 1 | Out | 完成脉冲 |
| ap_idle | 1 | Out | 空闲状态 |
| ctrl_weight_dma_req | 1 | Out | 权重 DMA 请求 |
| i_weight_valid | 1 | In | 权重缓冲有效 |
| i_weight_dma_beat | 1 | In | DMA beat 握手 |
| ctrl_weight_load_en | 1 | Out | 权重加载使能 |
| i_input_valid | 1 | In | 输入缓冲有效 |
| ctrl_input_stream_en | 1 | Out | 输入读取使能 |
| ctrl_drain_en | 1 | Out | 排空使能 |
| dbg_cnt_* | 32 | Out | 调试计数 |
| i_dbg_clr | 1 | In | 清除计数器 |

## 4. 时序/延迟
- S_LOAD_W 阶段分两段：
  - DMA 填充（计数 i_weight_dma_beat）
  - Buffer->Array 加载（计数 i_weight_valid）
- S_COMPUTE 阶段仅在 i_input_valid=1 时推进序列计数。
- S_DRAIN 持续 LATENCY 周期后进入 DONE。

## 5. 关键设计机制
- FSM 状态：IDLE -> LOAD_W -> COMPUTE -> DRAIN -> DONE。
- 计数器用于精确控制每个阶段的周期。

## 6. 复位/初始化
- rst_n 清零 FSM 与计数器。
- i_dbg_clr 可在运行中清零计数器。
