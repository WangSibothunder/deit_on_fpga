# Input Buffer Controller 规格书

Version: 1.2
Date: 2026-03-08
Module: input_buffer_ctrl.v
Status: 文档更新（未重新验证）

## 1. 模块概述
input_buffer_ctrl 是数据通路入口缓冲，负责将 AXI-Stream 的 64-bit 数据转换为脉动阵列所需的 96-bit 并行向量，并通过 Ping-Pong 机制实现计算与加载重叠。

主要功能：
- Gearbox：3 个 64-bit 输入重组为 2 个 96-bit 输出。
- Ping-Pong Buffer：双 Bank 交替读写，掩盖 DMA 传输延迟。
- Pipeline Alignment：写地址打一拍对齐，读端采用 lookahead 读。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| DEPTH_LOG2 | 8 | 单 Bank 深度为 2^DEPTH_LOG2（默认 256） |
| DATA_WIDTH | 64 | AXI-Stream 数据宽度 |

## 3. 接口定义
### 3.1 Global
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk | 1 | In | 时钟 |
| rst_n | 1 | In | 低有效复位 |

### 3.2 AXI-Stream Slave（写端）
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| s_axis_tdata | DATA_WIDTH | In | 输入数据 |
| s_axis_tvalid | 1 | In | 数据有效 |
| s_axis_tready | 1 | Out | 恒为 1（不背压） |
| s_axis_tlast | 1 | In | 预留，当前未使用 |

### 3.3 Core 读端
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_rd_en | 1 | In | Core 读取使能 |
| o_array_vec | 96 | Out | 12 行 * 8-bit 向量 |
| o_dat_valid | 1 | Out | 输出数据有效 |

### 3.4 Control
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_bank_swap | 1 | In | Bank 翻转触发 |

### 3.5 Debug
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| dbg_ibuf_wr_ptr | 8 | Out | 写指针低 8 位 |

## 4. 时序/延迟
- Gearbox：3 个 64b 输入 -> 2 个 96b 写入。
- RAM 读端口 1 拍延迟。
- o_dat_valid = i_rd_en 延迟 1 拍（与数据对齐）。
- i_bank_swap 触发 bank_sel 翻转，并清零读写指针。

## 5. 关键设计机制
- 3-to-2 Gearbox：通过 gb_state 与 temp_reg 拼接数据。
- wr_addr_pipe：将写地址打一拍，避免 ram_wen 与地址错位。
- Ping-Pong：单块双倍深度 RAM，地址高位作为 Bank 选择。
- Lookahead 读：o_dat_valid 为 1 时读地址前瞻到下一项。

## 6. 复位/初始化
- rst_n 清除状态机、指针与临时寄存器。
- RAM 在仿真中初始化为 0，避免 X 传播。

## 7. 调试信号
- dbg_ibuf_wr_ptr：观察写入进度与 Bank 状态。
