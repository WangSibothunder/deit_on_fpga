DeiT-Tiny FPGA Accelerator Design Specification

Project Name: DeiT-Tiny Hardware Accelerator

Target Platform: Xilinx Zynq-7020 (CLG400)

Role: Principal FPGA Architect Team

Date: 2025-12

Status: Phase 4 Complete (Core Integration Verified)

1. 项目愿景与架构 (Architecture Overview)

本项目旨在资源受限的边缘端 FPGA 上实现 Vision Transformer (DeiT-Tiny) 的高效推理。

1.1 系统级架构 (System Level)

采用 软硬协同 (HW/SW Co-design) 策略：

PS (Processing System - ARM Cortex-A9):

负责复杂非线性算子 (Softmax, GELU, LayerNorm)。

负责任务调度 (Tiling Control) 和数据搬运 (DMA Configuration)。

PL (Programmable Logic - FPGA):

DeiT Core: 专用的矩阵乘法加速器 (GEMM Engine)。

Dataflow: Weight Stationary (权重驻留) + Output Stationary Accumulation (输出累加)。

Precision: INT8 输入/权重，INT32 累加。

1.2 顶层数据流 (Top-Level Dataflow)

DDR (Weights/Inputs) -> AXI DMA -> On-chip Buffers -> DeiT Core -> Accumulator -> AXI DMA -> DDR

2. 工作空间规范 (Workspace Standard)

2.1 目录结构 (Directory Structure)

所有开发活动必须遵循以下文件组织：

.
├── LLM文档/                  # 交互历史与架构决策记录
│   ├── 0systemprompt.md     # 角色设定
│   ├── 1phase1.md           # 架构设计
│   ├── 2phase1.md           # 模块规格说明
│   └── 2phase2.md           # 详细设计文档
├── roadmap.md               # 项目进度追踪
├── src/                     # RTL 源码与验证平台
│   ├── params.vh            # [Global] 全局参数 (ARRAY_ROW=12, ARRAY_COL=16)
│   ├── deit_core.v          # [Top] 核心顶层 (Skew/Deskew/Integration)
│   ├── global_controller.v  # [Ctrl] 全局状态机
│   ├── systolic_array.v     # [Compute] 脉动阵列顶层
│   ├── pe.v                 # [Compute] 计算单元
│   ├── accumulator_bank.v   # [Memory] 累加器堆
│   ├── single_column_bank.v # [Memory] 单列存储 Bank
│   ├── gen_vectors.py       # [Verify] Python 黄金向量生成器
│   ├── *_tb.v               # [Verify] 各模块 Testbench
│   └── test_data/           # [Data] 仿真生成的 .mem 文件
├── run_simulation.sh        # [Script] 标准一键仿真脚本
├── simulate_module.sh       # [Script] 模块级调试脚本
└── simulate_core.sh         # [Script] 核心级调试脚本


2.2 验证工作流 (Verification Workflow)

所有模块必须通过 Python-Driven Co-Simulation 验证。

标准脚本模板 (run_simulation.sh):

#!/bin/bash

# 1. 环境准备
mkdir -p src/test_data

# 2. 生成黄金向量 (Python)
echo "[1/3] Generating Test Vectors..."
python src/gen_vectors.py
if [ $? -ne 0 ]; then echo "Python script failed."; exit 1; fi

# 3. 编译 RTL (iVerilog)
# 必须显式包含所有依赖，推荐使用 -g2005-sv 支持 SystemVerilog 特性
echo "[2/3] Compiling RTL..."
MODULE_NAME="deit_core_verify"
SIM_OUT="src/${MODULE_NAME}_sim.out"
TB_FILE="src/deit_core_verify_tb.v"

iverilog -I src -g2005-sv -o $SIM_OUT \
    src/params.vh \
    src/pe.v \
    src/single_column_bank.v \
    src/global_controller.v \
    src/systolic_array.v \
    src/accumulator_bank.v \
    src/deit_core.v \
    $TB_FILE

if [ $? -ne 0 ]; then echo "Verilog compilation failed."; exit 1; fi

# 4. 运行仿真 (VVP)
echo "[3/3] Running Simulation..."
vvp $SIM_OUT

# 5. 调试 (GTKWave)
echo "Done. To view waveforms: gtkwave core_verify.vcd"


3. PL 侧硬件模块详解 (Hardware Specifications)

3.1 核心顶层：deit_core (Verified)

文件: src/deit_core.v
层级: Top Level Component
功能: 封装计算、控制与存储子系统。负责解决脉动阵列的时序倾斜（Skew）问题，对上层提供统一的“块”级接口。

关键逻辑:

Input Skew (Rect -> Diamond): 将并行输入的 Activation 转换为脉动所需的倾斜波前。

Row $i$ 延迟 $i$ 个周期。

Output Deskew (Diamond -> Rect): 将阵列输出的倾斜波前重新对齐。

Col $j$ 延迟 $15-j$ 个周期。

Latency Compensation: 生成全局写使能信号 acc_wr_en。

LATENCY = ARRAY_ROW + ARRAY_COL + 2 (当前调试值: 30/31)。

接口定义:
| 信号名 | 方向 | 位宽 | 描述 |
| :--- | :--- | :--- | :--- |
| clk, rst_n | In | 1 | 100MHz 时钟与低电平复位 |
| ap_start | In | 1 | 启动信号 (Pulse) |
| cfg_compute_cycles | In | 32 | 计算序列长度 M (例如 16) |
| cfg_acc_mode | In | 1 | 0: Overwrite (First Tile), 1: Accumulate |
| ap_done, ap_idle | Out | 1 | 状态指示 |
| in_act_vec | In | R*8 | 输入数据向量 (Flattened) |
| in_weight_vec | In | C*8 | 权重数据向量 (Flattened) |
| out_acc_vec | Out | C*32 | 累加器输出结果 |
| ctrl_weight_load_en | Out | 1 | 请求外部 Weight Buffer 读取 |
| ctrl_input_stream_en | Out | 1 | 请求外部 Input Buffer 读取 |

3.2 控制平面：global_controller

文件: src/global_controller.v
功能: 主状态机，协调加载、计算和排空流程。

状态机 (FSM):

IDLE: 等待 Start。

LOAD_W: 加载权重 (持续 ARRAY_ROW 周期)。

COMPUTE: 计算核心 (持续 M 周期)。

DRAIN: 等待流水线排空。重要: DRAIN_CYCLES 必须 > 系统总延迟 (Latency)，否则会导致 Accumulator 地址提前复位，丢弃末尾数据。

DONE: 发出完成中断。

3.3 计算平面：systolic_array

文件: src/systolic_array.v
功能: $12 \times 16$ 二维脉动阵列。
物理特性:

Latency: $12 + \text{Col\_Index}$。

Dataflow: Weight Stationary。输入从左至右，部分和从上至下。

子模块: pe (Processing Element)

文件: src/pe.v

功能: INT8 MAC (Multiply-Accumulate)。

逻辑:

if (load): reg_w <= in_w

if (compute): psum <= psum + (act * reg_w) (利用 DSP48)

3.4 存储平面：accumulator_bank

文件: src/accumulator_bank.v
功能: 16 个独立的存储 Bank，支持高带宽并行写入与 RMW (读-改-写) 操作。

子模块: single_column_bank

文件: src/single_column_bank.v

实现: Distributed RAM (LUTRAM)。

优势: 异步读 (Asynchronous Read)，使得 Read-Add-Write 可以在单周期内完成，无需复杂的流水线转发逻辑。

逻辑:

Overwrite: mem[addr] <= input

Accumulate: mem[addr] <= mem[addr] + input

4. 完整的 PL 顶层设计规划 (Future Roadmap)

目前的 deit_core 仅包含了计算核心。为了构成完整的 PL 加速器（Overlay），我们需要在 deit_core 外围添加以下组件：

4.1 待开发组件清单

AXI-Lite Slave Interface (axi_lite_control.v):

功能: 允许 PS 端通过寄存器读写配置 ap_start, cfg_compute_cycles, cfg_acc_mode 等参数，并查询状态。

地址映射:

0x00: Control Reg (Start/Reset)

0x04: Status Reg (Done/Idle)

0x08: Dimension Config (M, K, N)

On-chip Buffers (BRAM Controllers):

input_buffer_ctrl.v: 双缓冲 (Ping-Pong) BRAM，用于缓存 Activation。支持 AXI-Stream 写入和 Core 并行读取。

weight_buffer_ctrl.v: 权重缓存，支持从 DDR 预取。

output_buffer_ctrl.v: 缓存 out_acc_vec 的结果，等待 DMA 取走。

Post-Processing Unit (ppu.v):

位置: 位于 Accumulator 和 Output Buffer 之间。

功能: Quantization (INT32 -> INT8)。

公式: Clamp((Acc + Bias) * Scale >> Shift)。

AXI-Stream Interface (axis_wrapper.v):

封装上述 Buffer，提供标准的 AXI-Stream 接口与 Zynq 的 AXI DMA IP 核相连。

4.2 顶层数据流图 (The Big Picture)

       +-------------------------------------------------------+
       |                  Zynq PS (DDR Memory)                 |
       +---------------------------+---------------------------+
                                   |
                            AXI4-Stream (DMA)
                                   v
+----------------------------------+----------------------------------+
|                        PL Top (Accelerator)                         |
|                                                                     |
|  +--------------+       +--------------+       +--------------+     |
|  | Input Buffer |       | Weight Buffer|       | Output Buffer|     |
|  | (Ping-Pong)  |       | (Linear)     |       | (FIFO/BRAM)  |     |
|  +------+-------+       +------+-------+       +-------+------+     |
|         |                      |                       ^            |
|         v                      v                       |            |
|  +-----------------------------------------------------+------+     |
|  |                      deit_core (Current)                   |     |
|  |                                                            |     |
|  |   [Skew] -> [Systolic Array] -> [Deskew] -> [Accumulator]  |     |
|  |                                                     |      |     |
|  +-----------------------------------------------------+------+     |
|                                                        |            |
|                                                        v            |
|                                                 [PPU (Quant)]       |
|                                                        |            |
+--------------------------------------------------------+------------+


5. 当前调试备忘 (Debug Notes)

时序对齐: 核心集成的关键在于 deit_core.v 中的 LATENCY 参数。每次修改 TB 的驱动逻辑或 Array 深度时，必须重新校准此参数。

数据流冻结: 务必保证 en_compute 在输入结束后继续有效（利用 Drain 信号），否则流水线中的数据会丢失。

地址复位: global_controller 的 DRAIN_CYCLES 必须足够长，防止 Accumulator 的地址计数器在数据写完前被复位。

Document Version: 1.0 (Phase 4 Verified)