# Weight Buffer Controller 规格书

Version: 1.1
Date: 2026-03-08
Module: weight_buffer_ctrl.v
Status: 文档更新（未重新验证）

## 1. 模块概述
weight_buffer_ctrl 管理权重加载流程，将 AXI-Stream 的 64-bit 权重流转换为 128-bit 行权重，并以 Ping-Pong 方式供阵列读取。

主要功能：
- 2-to-1 Gearbox：2 个 64-bit 输入组成 1 个 128-bit 权重行。
- Ping-Pong Buffer：支持预加载下一组权重。
- Pipeline Alignment：写地址打拍、读端 lookahead 对齐。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| DEPTH_LOG2 | 4 | 单 Bank 深度为 16 行 |
| OUT_WIDTH | ARRAY_COL*8 | 权重行宽度（默认 128b） |

## 3. 接口定义
### 3.1 AXI-Stream Slave
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| s_axis_tdata | 64 | In | 权重输入 |
| s_axis_tvalid | 1 | In | 数据有效 |
| s_axis_tready | 1 | Out | 恒为 1（不背压） |

### 3.2 Core 读端
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_weight_load_en | 1 | In | 权重读取使能 |
| o_weight_vec | 128 | Out | 16 列权重向量 |
| o_dat_valid | 1 | Out | 输出数据有效 |

### 3.3 Control
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_bank_swap | 1 | In | Bank 翻转触发 |

### 3.4 Debug
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| dbg_wbuf_wr_ptr | 4 | Out | 写指针 |
| dbg_wbuf_ram_wen | 1 | Out | RAM 写使能 |
| dbg_wbuf_gb_cnt | 1 | Out | Gearbox 状态 |

## 4. 时序/延迟
- Gearbox：每 2 个 64b 输入产生 1 个 128b 写入。
- RAM 读延迟 1 拍。
- o_dat_valid = i_weight_load_en 延迟 2 拍。
- i_bank_swap 翻转读写 Bank 并清写指针。

## 5. 关键设计机制
- 写地址管线：wr_addr_pipe 与 ram_wen 对齐，避免首拍错位。
- Ping-Pong：读端访问 ~bank_sel；写端访问 bank_sel。
- Lookahead 读：o_dat_valid 为 1 时，读地址前瞻到下一项。

## 6. 复位/初始化
- rst_n 清除 Gearbox、指针与 valid 管线。
- RAM 仿真初始化为 0。

## 7. 调试信号
- dbg_wbuf_wr_ptr / dbg_wbuf_ram_wen / dbg_wbuf_gb_cnt 用于观察写入与 Gearbox 状态。
