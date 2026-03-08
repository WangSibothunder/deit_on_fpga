# PL 侧 RTL 项目总说明书 (DeiT 加速器, 完整版)

【UTF-8文档校验行】：UTF8_TEST=中文，如果看到正常中文说明编码正确。

版本：2.2
日期：2026-03-08
覆盖范围：src/rtl 以及 docs 中相关模块规格书
编码：UTF-8

---

## 1. 全局概览
本项目在 PL 侧实现 DeiT 推理的矩阵乘加主干，目标是以可控的时序、可复用的缓存结构与明确的握手协议，将大规模矩阵运算映射到二维脉动阵列。系统由 AXI-Lite 控制面、AXI-Stream 数据面、三类缓冲（输入/权重/输出）与核心计算阵列组成。全局策略采用“权重预加载 + 输入流计算 + 排空输出”的三阶段流水，确保计算单元高利用率，同时减少 PS 端等待。

### 1.1 架构连线图
```mermaid
flowchart LR
    subgraph PS[PS 侧]
        DDR[(DDR Memory)]
        DMA_IN[AXI DMA IN]
        DMA_OUT[AXI DMA OUT]
        AXIL[AXI-Lite Control]
    end
    subgraph PL[PL 侧]
        IBUF[Input Buffer]
        WBUF[Weight Buffer]
        CORE[DeiT Core]
        ARRAY[Systolic Array]
        ACC[Accumulator Bank]
        PPU[PPU Quantization]
        OBUF[Output Buffer]
    end

    AXIL --> CORE
    AXIL --> IBUF
    AXIL --> WBUF
    AXIL --> OBUF

    DDR --> DMA_IN --> IBUF --> CORE --> ARRAY --> ACC --> PPU --> OBUF --> DMA_OUT --> DDR
    DMA_IN --> WBUF --> CORE
```

### 1.2 全局控制 FSM 状态图
```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> LOAD_W: ap_start
    LOAD_W --> COMPUTE: 权重装载完成
    COMPUTE --> DRAIN: 输入序列完成
    DRAIN --> DONE: 排空完成
    DONE --> IDLE: 自动返回
```

### 1.3 全局数据流动（端到端）
以下描述从“PS 配置 → PL 计算 → PS 回读”的完整数据通路，重点说明每一级缓存/控制的作用。

1. PS 通过 AXI-Lite 写寄存器，设置 cfg_seq_len、cfg_mult、cfg_shift、cfg_zp、cfg_bias 等参数，并拉高 ap_start。
2. 权重与输入通过 AXI DMA 以 AXI-Stream 写入 PL：权重进入 weight_buffer_ctrl，输入进入 input_buffer_ctrl。
3. weight_buffer_ctrl 使用 64b→128b Gearbox 将两拍权重拼成阵列所需宽度，并写入 Ping-Pong Bank 的“后台 Bank”。
4. input_buffer_ctrl 使用 3×64b→2×96b Gearbox 将输入拼接成阵列行向量，并写入当前 Bank。
5. global_controller 进入 LOAD_W 状态，发出 ctrl_weight_dma_req 与 ctrl_weight_load_en，驱动 core 按行加载权重。
6. 进入 COMPUTE 状态后，ctrl_input_stream_en 打开输入读取；input_buffer_ctrl 按 i_rd_en 读出激活向量。
7. deit_core 将输入向量进行 Input Skew，权重进行时序对齐后送入 systolic_array。
8. systolic_array 执行乘加，输出列级 psum；Output Deskew 补偿列延迟使输出对齐。
9. accumulator_bank 按 addr/acc_mode 覆盖或累加 psum，实现多 tile 的逐列累加。
10. ppu 对累加结果进行 bias/scale/shift/zero-point 量化，并输出 INT8。
11. output_buffer_ctrl 将 128b 结果拆分为 64b，按帧产生 tlast 并输出 AXI-Stream。
12. DMA_OUT 将结果写回 DDR，PS 侧读取并进入后续 softmax/后处理。

### 1.4 全局数据流动（阶段视角）
- LOAD_W 阶段：权重流为主，input_buffer_ctrl 仅进行预填充；core 生成 row_load_en，阵列权重寄存器被填满。
- COMPUTE 阶段：输入流与权重并行，阵列每拍消耗一行输入并产生 psum；输出经累加和 PPU 后写入输出缓冲。
- DRAIN 阶段：输入停止，阵列剩余流水继续输出；output_buffer_ctrl 负责完整帧尾和 tlast 对齐。

### 1.5 局部数据流动（模块视角）
- input_buffer_ctrl：AXI-Stream → Gearbox → Ping-Pong RAM → 核心输入向量。
- weight_buffer_ctrl：AXI-Stream → Gearbox → Ping-Pong RAM → 核心权重行加载。
- deit_core：Input Skew + Weight Align → Systolic Array → Deskew → Accumulator → PPU。
- output_buffer_ctrl：PPU 结果 → FIFO → 64b AXI-Stream + tlast。
- global_controller：控制信号在 LOAD_W/COMPUTE/DRAIN 状态间切换，决定数据是否流动。

### 1.6 关键时序对齐与缓冲策略
- 输入/权重 Gearbox 将不匹配的总线宽度转化为阵列宽度，减少阵列边界逻辑。
- Input Skew 与 Output Deskew 分别解决行/列时序错位问题，保证矩阵乘加输出在列维度对齐。
- o_dat_valid 与数据路径通过寄存器延迟线对齐，避免“valid 早/晚”引发的写错位。
- Ping-Pong Bank 允许“边计算边加载”，在 bank_swap 时切换读写角色，实现双缓冲。

---

## 2. 模块级规格书汇总

### 2.X 模块：accumulator_bank

# Accumulator Bank 规格书

Version: 1.0
Date: 2026-03-08
Module: accumulator_bank.v
Status: 新增文档

## 1. 模块概述
accumulator_bank 是 16 列累加器 Bank 的顶层封装，统一地址/写使能/模式控制，同时并行读写每列累加器。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| ADDR_WIDTH | 8 | 地址位宽，深度为 2^ADDR_WIDTH |

## 3. 接口定义
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| addr | ADDR_WIDTH | In | 统一地址 |
| wr_en | 1 | In | 统一写使能 |
| acc_mode | 1 | In | 0=覆盖，1=累加 |
| in_psum_vec | 16*32 | In | 16 路输入部分和 |
| out_acc_vec | 16*32 | Out | 16 路累加输出 |

## 4. 时序/延迟
- 子模块采用写穿透逻辑，写当拍即可观察到新值。

## 5. 关键设计机制
- generate 生成 16 个 single_column_bank。
- 向量切片按列映射输入/输出。

## 6. 复位/初始化
- 复位与初始化由子模块 single_column_bank 处理。

## 局部数据流动
- in_psum_vec 分片成 16 列，分别送入 single_column_bank。
- addr / wr_en / acc_mode 广播到所有列，保证同地址对齐读改写。
- 单列 Bank 采用 RMW 流程并写穿透旁路，写入拍即可输出新值。
- out_acc_vec 将 16 列输出重新拼接，供 PPU 或后级消费。
- 仿真初始化清零 RAM，避免未写区域的 X 传播。


### 2.X 模块：axi_lite_control

# AXI-Lite Control 规格书

Version: 1.0
Date: 2026-03-08
Module: axi_lite_control.v
Status: 新增文档

## 1. 模块概述
AXI4-Lite 从接口寄存器映射，提供启动、复位、计算配置、PPU 配置与调试寄存器访问。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| C_S_AXI_DATA_WIDTH | 32 | AXI 数据宽度 |
| C_S_AXI_ADDR_WIDTH | 6 | AXI 地址宽度 |

## 3. 接口定义
### 3.1 AXI4-Lite Slave
标准 s_axi_* 信号。

### 3.2 Core Control
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| o_ap_start | 1 | Out | 启动脉冲 |
| o_soft_rst_n | 1 | Out | 软复位（高有效） |
| o_cfg_compute_cycles | 32 | Out | 计算长度 |
| o_cfg_acc_mode | 1 | Out | 累加模式 |
| i_ap_done | 1 | In | 完成 |
| i_ap_idle | 1 | In | 空闲 |

### 3.3 PPU Config
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| o_ppu_mult | 16 | Out | 乘数 |
| o_ppu_shift | 5 | Out | 右移 |
| o_ppu_zp | 8 | Out | Zero Point |
| o_ppu_bias | 32 | Out | Bias |
| o_output_en | 1 | Out | PPU 输出使能 |

### 3.4 Debug
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_dbg0..i_dbg3 | 32 | In | 调试输入寄存器 |
| o_dbg_snap | 1 | Out | 采样脉冲 |
| o_dbg_clr | 1 | Out | 清计数器脉冲 |

## 4. 寄存器映射（字地址）
| 地址 | 名称 | 描述 |
| --- | --- | --- |
| 0x00 | CTRL | bit0: ap_start(W1P), bit1: soft_rst_n |
| 0x04 | STATUS | bit0: ap_done(sticky W1C), bit1: ap_idle |
| 0x08 | CFG_K | 计算长度 |
| 0x0C | CFG_ACC | bit0: acc_mode |
| 0x10 | VERSION | 版本号 |
| 0x14 | PPU_MULT | 乘数 |
| 0x18 | PPU_SHIFT | 右移 |
| 0x1C | PPU_ZP | Zero Point |
| 0x20 | PPU_BIAS | Bias |
| 0x24 | OUTPUT_EN | bit0: 使能 |
| 0x28 | DBG_SNAP | 写 1 采样 dbg0-3 |
| 0x2C | DBG_CLR | 写 1 清计数 |
| 0x30~0x3C | DBG0~DBG3 | 采样寄存器 |

## 5. 时序/延迟
- 写通道要求 AWVALID 与 WVALID 同拍握手。
- 读通道 ARVALID 后单拍返回 RVALID。
- o_ap_start/o_dbg_* 为脉冲型输出。

## 6. 复位/初始化
- rst_n 清零所有寄存器。

## 局部数据流动
- AXI-Lite 写通道接收 awaddr + wdata，组合成寄存器写入请求。
- wstrb 按字节选择性写入，支持字段级覆盖。
- 读通道根据 araddr 选择寄存器并返回 rdata。
- 寄存器输出驱动 ap_start 与各类 cfg_*，直接控制 Core/PPU/Buffer。
- 状态与调试计数回写到读通道，供 PS 侧轮询。
- bresp / rresp 固定为 OKAY，协议路径保持简单。


### 2.X 模块：deit_accelerator_top

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


### 2.X 模块：deit_core

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


### 2.X 模块：global_controller

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

## 局部数据流动
- ap_start 触发状态机进入 LOAD_W，cfg_seq_len 决定 COMPUTE 周期。
- ctrl_weight_dma_req 指示 PS/DMA 拉权重，i_weight_dma_beat 计数。
- ctrl_weight_load_en 打开权重装载窗口并驱动 row_load_en。
- ctrl_input_stream_en 允许输入流读取，i_input_valid 用于对齐。
- ctrl_drain_en 在计算结束后保持输出 drain。
- ap_done 在 DONE 周期拉高，ap_idle 在 IDLE 维持高电平。

## 状态机控制图
```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> LOAD_W: ap_start
    LOAD_W --> COMPUTE: cnt_wload >= WEIGHT_ROWS
    COMPUTE --> DRAIN: cnt_seq >= cfg_seq_len-1
    DRAIN --> DONE: cnt_drain >= LATENCY-1
    DONE --> IDLE: 1
```


### 2.X 模块：input_buffer_ctrl

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

## 局部数据流动
- s_axis_tdata 进入 3×64b→2×96b Gearbox，gb_state 轮转拼接。
- ram_wen 与 wr_addr_pipe 对齐后写入当前 bank。
- i_bank_swap 触发 bank_sel 翻转并清空读写指针。
- i_rd_en 发起读请求，o_dat_valid 延迟 1 拍输出。
- o_array_vec 作为 deit_core 的输入激活向量。
- s_axis_tready 恒为 1，帧边界由 i_bank_swap 控制。

## 状态机控制图
```mermaid
stateDiagram-v2
    [*] --> GB0
    GB0 --> GB1: s_axis_tvalid
    GB1 --> GB2: s_axis_tvalid
    GB2 --> GB0: s_axis_tvalid
    GB0 --> GB0: i_bank_swap
    GB1 --> GB0: i_bank_swap
    GB2 --> GB0: i_bank_swap
```


### 2.X 模块：output_buffer_ctrl

# Output Buffer Controller 规格书

Version: 1.0
Date: 2026-03-08
Module: output_buffer_ctrl.v
Status: 新增文档

## 1. 模块概述
输出缓冲模块，包含 128b FIFO 与 128->64 Gearbox，输出 AXI-Stream 帧并生成 tlast。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| DEPTH_LOG2 | 8 | FIFO 深度 = 2^DEPTH_LOG2 |

## 3. 接口定义
### 3.1 写端 (PPU)
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_data | 128 | In | 写入数据 |
| i_valid | 1 | In | 写入有效 |
| o_full | 1 | Out | FIFO 满 |

### 3.2 读端 (AXI-Stream)
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| axis_tdata | 64 | Out | 输出数据 |
| axis_tvalid | 1 | Out | 输出有效 |
| axis_tready | 1 | In | 下游就绪 |
| axis_tlast | 1 | Out | 帧结束 |

### 3.3 配置
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| i_cfg_seq_len | 32 | In | 序列长度，帧 beat 数为 seq_len*2 |

### 3.4 Debug
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| dbg_obuf_wr_ptr | 8 | Out | 写指针 |
| dbg_obuf_rd_ptr | 8 | Out | 读指针 |
| dbg_obuf_full | 1 | Out | FIFO 满 |

## 4. 时序/延迟
- FIFO 写入无延迟。
- 读端 FSM 每 2 拍输出 1 个 128b。
- axis_tlast 在帧内最后一个 beat 置 1。

## 5. 关键设计机制
- 读端 FSM：IDLE -> HALF0 -> HALF1。
- frame_beats = i_cfg_seq_len << 1。

## 6. 复位/初始化
- rst_n 清零指针与状态机。

## 局部数据流动
- i_data/i_valid 写入 128b FIFO，o_full 反馈上游背压。
- 读端 FSM 从 FIFO 取 128b，分两拍输出 64b。
- axis_tready 握手控制 beat 递增与 rd_ptr 更新。
- i_cfg_seq_len 映射为 frame_beats=seq_len*2，驱动 tlast。
- frame_active 在帧内保持稳定，帧尾回到 IDLE。
- dbg_obuf_* 指针用于定位丢包与背压问题。

## 状态机控制图
```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> HALF0: !empty
    HALF0 --> HALF1: axis_tvalid && axis_tready
    HALF1 --> IDLE: axis_tvalid && axis_tready
```


### 2.X 模块：pe

# Processing Element (PE) 规格书

Version: 1.0
Date: 2026-03-08
Module: pe.v
Status: 新增文档

## 1. 模块概述
PE 为脉动阵列的基本计算单元，采用 Weight Stationary 数据流，支持权重加载与 MAC 计算。

## 2. 接口定义
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| en_compute | 1 | In | 启用计算 |
| load_weight | 1 | In | 权重加载 |
| in_act | 8 | In | 左侧激活输入 |
| in_weight | 8 | In | 权重输入 |
| in_psum | 32 | In | 上方部分和 |
| out_act | 8 | Out | 右侧激活输出 |
| out_psum | 32 | Out | 下方部分和输出 |

## 3. 时序/延迟
- load_weight 在本拍写入 reg_weight，计算使用旧权重，新权重下拍生效。
- en_compute 时输出更新，等效 1 拍流水。

## 4. 关键设计机制
- MAC：out_psum = in_psum + in_act * reg_weight。
- Dataflow：激活从左到右传递，部分和从上到下传递。

## 5. 复位/初始化
- rst_n 清零 reg_weight / out_act / out_psum。

## 局部数据流动
- 每个 PE 接收 in_act 与 in_weight，组合乘法得到局部乘积。
- 乘积与 in_psum 累加形成 out_psum。
- 激活向下传递、权重向右传递，维持阵列流动。
- en_compute 控制计算使能，复位清零内部寄存器。


### 2.X 模块：ppu

# Post-Processing Unit (PPU) 规格书

Version: 1.1
Date: 2026-03-08
Module: ppu.v
Status: 文档更新（未重新验证）

## 1. 模块概述
PPU 对阵列输出的 INT32 做定点量化，输出 INT8，支持 bias、scale、shift、zero-point，满足量化推理输出要求。

## 2. 参数
无显式参数（使用 `params.vh` 中的 ARRAY_COL 等宏）。

## 3. 接口定义
### 3.1 Data Path
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| i_valid | 1 | In | 输入有效 |
| i_data_vec | 16*32 | In | 16 路 INT32 输入 |
| o_valid | 1 | Out | 输出有效（延迟 1 拍） |
| o_data_vec | 16*8 | Out | 16 路 INT8 输出 |

### 3.2 Configuration
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| cfg_mult | 16 | In | 定点乘数 |
| cfg_shift | 5 | In | 右移位数 |
| cfg_zp | 8 | In | Zero Point |
| cfg_bias | 32 | In | Bias（INT32） |

## 4. 时序/延迟
- 每个 lane 为组合计算 + 1 拍寄存输出。
- o_valid = i_valid 延迟 1 拍。

## 5. 关键设计机制
- 计算链：bias -> 乘法 -> 右移 -> 加零点 -> Clamp。
- Clamp 范围：[-128, 127]。

## 6. 复位/初始化
- rst_n 清零输出寄存器。

## 7. 备注
- 如果 DSP/时序压力较大，可将 PPU 进行序列化（每拍处理部分 lane）。

## 局部数据流动
- 输入 16×INT32 psum，逐 lane 加 bias。
- 乘以 cfg_mult 并右移 cfg_shift 完成缩放。
- 加 cfg_zp 进行零点偏移，饱和截断到 INT8。
- 输出寄存器打拍，o_valid 延迟 1 拍。
- 结果拼接成 128b 写入输出缓冲。


### 2.X 模块：single_column_bank

# Single Column Bank 规格书

Version: 1.0
Date: 2026-03-08
Module: single_column_bank.v
Status: 新增文档

## 1. 模块概述
single_column_bank 实现单列累加器存储，支持覆盖或累加两种模式，采用读改写 (RMW) 流程并提供写穿透输出。

## 2. 参数
| 参数 | 默认 | 说明 |
| --- | --- | --- |
| BANK_ID | 0 | Bank 标识（调试用） |
| DEPTH_LOG2 | 8 | 深度为 2^DEPTH_LOG2 |

## 3. 接口定义
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| addr | DEPTH_LOG2 | In | 地址 |
| wr_en | 1 | In | 写使能 |
| acc_mode | 1 | In | 0=覆盖，1=累加 |
| in_psum | 32 | In | 输入部分和 |
| out_acc | 32 | Out | 输出累加值 |

## 4. 时序/延迟
- 读为组合，写为同步。
- 写穿透：wr_en=1 时输出 next_val。

## 5. 关键设计机制
- RMW：old_val 组合读出，next_val 组合计算。
- ram_style=\"distributed\" 优先 LUTRAM 推断。

## 6. 复位/初始化
- 仿真中初始化 RAM 为 0。

## 局部数据流动
- mem[addr] 异步读出 old_val 参与计算。
- acc_mode 决定覆盖或累加，生成 next_val。
- wr_en 高时同步写回 next_val。
- 写穿透旁路保证输出与写入同拍一致。
- 仿真初始化清零内存，避免 X 传播。


### 2.X 模块：systolic_array

# Systolic Array 规格书

Version: 1.0
Date: 2026-03-08
Module: systolic_array.v
Status: 新增文档

## 1. 模块概述
systolic_array 为参数化脉动阵列顶层，采用 Weight Stationary 数据流，完成并行矩阵乘累加。

## 2. 参数
使用 `params.vh` 中的宏：ARRAY_ROW、ARRAY_COL、DATA_WIDTH、ACC_WIDTH。

## 3. 接口定义
| 信号 | 宽度 | 方向 | 说明 |
| --- | --- | --- | --- |
| clk, rst_n | 1 | In | 时钟与复位 |
| en_compute | 1 | In | 全局计算使能 |
| row_load_en | ARRAY_ROW | In | 行级权重加载使能 |
| in_act_vec | ARRAY_ROW*DATA_WIDTH | In | 每行激活输入向量 |
| in_weight_vec | ARRAY_COL*DATA_WIDTH | In | 每列权重广播向量 |
| out_psum_vec | ARRAY_COL*ACC_WIDTH | Out | 最后一行的部分和输出 |

## 4. 时序/延迟
- 激活左进右出，部分和上进下出。
- 权重按列广播，row_load_en 控制按行加载。

## 5. 关键设计机制
- generate 生成 ROW x COL 个 PE。
- 第一列激活来自 in_act_vec，其余来自左侧 PE。
- 第一行部分和为 0，其余来自上方 PE。
- 最后一行输出连接到 out_psum_vec。

## 6. 复位/初始化
- 复位由各 PE 内部处理。

## 局部数据流动
- row_load_en 按行加载权重到 PE 行寄存器。
- in_act_vec 经 Input Skew 形成对角线数据流。
- 每拍完成乘加，psum 沿阵列流动。
- out_psum_vec 为列输出，延迟随列号递增。
- en_compute 允许暂停计算并保持阵列状态。


### 2.X 模块：weight_buffer_ctrl

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

## 局部数据流动
- s_axis_tdata 64b 进入 Gearbox，2 beat 拼成 128b。
- ram_wen 写入当前 bank，wr_addr_pipe 与数据对齐。
- i_bank_swap 翻转 bank 并清零 wr_ptr/gb_cnt。
- i_weight_load_en 触发读端，o_dat_valid 延迟 2 拍。
- lookahead 读地址保证 Data0,Data0,Data1 对齐阵列。
- o_weight_vec 输出到 core 行加载链路。


## 3. 时序对齐与连线总结
- 输入侧：Input Skew 使行数据形成对角线流，与 row_load_en 的加载节拍匹配。
- 权重侧：Gearbox + 对齐寄存器消除 valid 与数据相位差。
- 输出侧：Output Deskew 与 valid_delay_line 保证列输出对齐与写入节拍一致。
- 缓冲侧：Ping-Pong Bank 在 bank_swap 时切换读写角色，实现双缓冲并行。

## 4. 结论
该 PL 侧 RTL 工程通过“控制-缓冲-阵列”的分层设计，将 DeiT 的主干矩阵运算拆解为可验证、可复用的模块。全局控制 FSM 清晰划分加载/计算/排空阶段，局部模块通过 Gearbox、Skew/Deskew、RMW 累加与 PPU 量化实现数据对齐与格式转换。配合 PS 侧 DMA 与双缓冲策略，可在较低控制复杂度下获得持续的阵列利用率，并在工程上保持可维护性与可扩展性。
