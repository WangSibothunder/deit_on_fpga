# DeiT Core 规格书

Version: 1.0
Date: 2026-03-08
Module: deit_core.v
Status: 新增文档

## 1. 模块概述
核心计算模块，包含控制器、脉动阵列、输入输出对齐与累加器管理。负责将输入/权重流与阵列时序对齐，并生成可写入累加器的有效信号。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| LATENCY_CFG | 28 | 流水线总延迟配置 |
| ADDR_WIDTH | 8 | 累加器地址宽度 |

## 3. 接口定义
### 3.1 Control
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| ap_start | 1 | In | 启动 |
| cfg_compute_cycles | 32 | In | 计算长度 |
| cfg_acc_mode | 1 | In | 累加模式 |
| ap_done | 1 | Out | 完成 |
| ap_idle | 1 | Out | 空闲 |

### 3.2 Data
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| in_act_vec | ARRAY_ROW*8 | In | 激活输入 |
| in_weight_vec | ARRAY_COL*8 | In | 权重输入 |
| out_acc_vec | ARRAY_COL*32 | Out | 累加输出 |

### 3.3 Handshake
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_weight_valid | 1 | In | 权重有效 |
| i_weight_dma_beat | 1 | In | DMA beat 握手 |
| i_input_valid | 1 | In | 输入有效 |
| i_dbg_clr | 1 | In | 清计数器 |

### 3.4 Buffer Control Out
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| ctrl_weight_load_en | 1 | Out | 权重加载 |
| ctrl_weight_dma_req | 1 | Out | 权重 DMA 请求 |
| ctrl_input_stream_en | 1 | Out | 输入读取 |

## 4. 时序/延迟
- 权重加载信号、权重数据与 valid 在入口统一打一拍对齐。
- 输入激活通过行内延迟链做输入 skew。
- valid_delay_line 长度为 LATENCY_CFG，用于对齐阵列输出与累加写使能。

## 5. 关键设计机制
- Controller 驱动多阶段流程与计数。
- Input Skew / Output Deskew 保证阵列对齐。
- Accumulator 写使能受 valid_delay_line 与 cfg_compute_cycles 限制。

## 6. 复位/初始化
- rst_n 清零对齐寄存器与计数器。

## 局部数据流动
- global_controller 生成权重加载、输入流使能与 drain 三类控制。
- in_act_vec 经 Input Skew 形成对角线数据流，匹配阵列节拍。
- in_weight_vec 延迟对齐后进入 systolic_array。
- systolic_array 输出 psum，Output Deskew 补偿列级延迟。
- accumulator_bank 根据 acc_mode 覆盖或累加，送入 PPU。
- valid_delay_line 与 i_input_valid 保证写入与输出对齐。
