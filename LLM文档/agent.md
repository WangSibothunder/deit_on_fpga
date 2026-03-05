Project Context & Handover: DeiT-Tiny FPGA Accelerator
项目名称: DeiT-Tiny Hardware Accelerator (Zynq-7020)
当前状态: Phase 5 Completed (Top-Level System Integration Verified)
角色: Google TPU Team Principal FPGA Architect
日期: 2026-01-19
1. Executive Summary (执行摘要)
本项目旨在 Xilinx Zynq-7020 (PYNQ) 平台上实现 Vision Transformer (DeiT-Tiny) 的端到端推理加速。
截至目前，我们已经完成了 PL (Programmable Logic) 端的全部核心设计与系统集成验证。
在 Phase 5 中，我们攻克了 Top-Level 集成中最棘手的时序与流控问题。通过引入全局握手协议 (Global Handshake Protocol) 和 解耦的输出缓冲 (Decoupled Output Buffer)，我们成功实现了无气泡、高吞吐的流水线计算。
关键里程碑:
[x] Systolic Array Pipeline: 实现了 12x16 脉动阵列的正确计算与累加。
[x] Memory Hierarchy: Input/Weight Buffer 的 Gearbox 与 Ping-Pong 机制验证通过。
[x] Flow Control: 修复了跨模块延迟导致的流水线错位，实现了基于 Valid 信号的精确流控。
[x] Output Stability: 引入 128-bit 宽、256 深度的 Output FIFO，彻底解决了 AXI Stream 输出端的幽灵数据与错位问题。
[x] Verification: simulate_top.sh 全系统仿真通过，Random Tiling 测试向量全部 PASS。
2. Directory Structure & File Manifest (目录与文件清单)
当前工程遵循严格的模块化结构。以下是核心文件及其功能描述，新 Session 必须基于这些最新版本工作。
src/ (RTL Source Code)
文件名
版本/状态
关键功能描述
deit_accelerator_top.v
v5.0 (Final)
顶层模块。集成了握手信号连接、DMA 下降沿 Swap 触发器、以及 Output Buffer 实例化。LATENCY_CFG 修正为 27。
deit_core.v
v3.5 (Handshake)
计算核心。新增 i_input/weight_valid 端口。实现了 row_load_en 的 Hold 逻辑和动态尾部门控 (acc_addr < cfg_compute_cycles)。
global_controller.v
v3.3 (Smart)
全局控制器。S_LOAD_W 和 S_COMPUTE 状态增加了握手等待逻辑。CNT_PHASE1_END 增加到 27 以宽容 DMA 延迟。
input_buffer_ctrl.v
v2.1 (Aligned)
输入缓冲。实现了 o_dat_valid (2-cycle latency) 输出，以及 RAM 全 0 初始化，防止指针越界读脏数据。
weight_buffer_ctrl.v
v2.1 (Aligned)
权重缓冲。实现了前瞻读取 (Lookahead Read) 和 RAM 全 0 初始化。
output_buffer_ctrl.v
v1.0 (New)
[新增] 输出缓冲。包含深度 256 的 FIFO 和解耦的发送状态机 (Pre-load FSM)，解决 AXI 输出不稳问题。
systolic_array.v
Stable
12x16 脉动阵列，纯组合逻辑+寄存器流水线。
accumulator_bank.v
Stable
累加器组顶层。
single_column_bank.v
v1.2 (Bypass)
单列累加器。实现了 Write-Through Bypass，解决了 Read-Modify-Write 的一拍旧数据问题。
ppu.v
Stable
后处理单元 (Bias, Scale, Quantize)。
axi_lite_control.v
Stable
AXI-Lite 寄存器接口 (6-bit 地址)。

src/ (Verification & Scripts)
文件名
描述
gen_vectors_top.py
[核心] Python Golden Model。生成支持分块 (Tiling) 的输入、权重和预期输出 (Partial/Final)。
debug_intermediate_calc.py
辅助调试脚本，用于生成中间累加器状态快照。
deit_accelerator_top_tb.v
顶层 Testbench。支持双 Tile 连续仿真，包含 AXI-Lite 配置序列。
simulate_top.sh
一键仿真脚本 (Icarus Verilog)。

3. Architecture Deep Dive (技术深潜)
为了让下一阶段的开发（真实权重验证与 PS 驱动）顺利进行，必须理解我们在 Phase 5 确立的三大架构原则。
3.1 The "Smart Pause" Handshake Protocol (智能暂停握手)
为了解决 Gearbox (64->96/128) 和 BRAM (1-cycle read) 带来的不确定延迟，我们摒弃了纯计数器逻辑，全面转向握手逻辑。
Weight Path: weight_buffer 输出 o_dat_valid。global_controller 在 S_LOAD_W 阶段持续发出 load_en，但只有当 valid=1 时，cnt_load 才递增。
Input Path: input_buffer 输出 o_dat_valid (延迟 2 周期)。global_controller 在 S_COMPUTE 阶段持续发出 read_en，但只有当 valid=1 时，cnt_seq 才递增。
Core Execution: deit_core 内部的 row_load_en (移位寄存器) 和 acc_wr_en (写使能链) 全部由 Valid 信号门控。
效果: 如果 Buffer 没准备好，整个流水线会**“冻结”**（Hold），而不是复位或错位。
3.2 Dynamic Boundary Protection (动态边界保护)
为了支持 DeiT-Tiny 中可变的 Sequence Length ($M$)（例如 $M=197$ 或 $M=16$），我们移除了硬编码的计数器。
机制: deit_core.v 中的 Accumulator 写逻辑：
wire acc_wr_en = acc_wr_en_raw & (acc_addr < cfg_compute_cycles);


意义: 无论流水线延迟多长，或者 Valid 信号如何抖动，这行代码作为最后一道防火墙，强制切断超过 $M$ 长度的写入，防止内存被写脏。
3.3 Decoupled Output Stage (解耦输出级)
这是解决 Top-Level 仿真卡死的关键。
问题: PPU 是突发输出 (128-bit/clk)，而 AXI Stream (64-bit) 受到 Gearbox 和 TREADY 的双重限制。直接耦合会导致 PPU 堵塞或数据丢失。
方案: output_buffer_ctrl.v
FIFO: 深度 256 (覆盖 $M=197$)。PPU 只管写 FIFO。
Fetcher & Sender: 发送端是一个独立的“生产者-消费者”模型。Fetcher 预读取数据到 data_reg，Sender 负责握手发送。这种设计完全消除了“幽灵数据”和重复发送。
4. Standard Operating Procedures (SOP)
SOP 1: 运行全系统仿真
这是验证任何 RTL 修改后的标准动作。
生成测试向量:
python3 src/gen_vectors_top.py

注意: 此脚本会生成 src/test_data_top/ 下的所有 .mem 文件，包括 config.mem。
执行仿真:
./src/simulate_top.sh
检查结果:
观察终端输出的 [PASS] / [FAIL]。
如果失败，打开 top_verify.vcd (推荐使用 GTKWave)。
SOP 2: 调试波形 (Waveform Debugging)
在 GTKWave 中，以下信号组合是最高效的调试切入点：
Group 1: Global State
deit_accelerator_top_tb.dut.u_control.current_state_dbg (FSM 状态)
deit_accelerator_top_tb.dut.u_control.cnt_load / cnt_seq (计数器)
Group 2: Data Flow Alignment
...u_core.in_act_vec (进入阵列的 Input)
...u_core.in_weight_vec (进入阵列的 Weight)
...u_core.i_input_valid / i_weight_valid (握手信号)
关键: 检查 Valid 变高时，Data 是否刚好是第一个有效数据。
Group 3: Accumulator & Output
...u_core.u_accum.u_bank_0.mem[0] (检查 RAM 内容)
...u_core.out_acc_vec (PPU 输入)
...u_out_buf.axis_tdata (最终输出)

5. Register Map (寄存器映射规范)
PS 端驱动开发必须严格遵守此映射 (Base Address + Offset)。
Offset
Name
R/W
Width
Description
0x00
CTRL_REG
R/W
32
Bit 0: ap_start (Pulse)Bit 1: soft_rst_n (Active Low, 0=Reset, 1=Run)
0x04
STATUS_REG
R
32
Bit 0: ap_doneBit 1: ap_idle
0x08
SEQ_LEN_REG
R/W
32
Sequence Length ($M$). 例如 32, 197。
0x0C
ACC_MODE
R/W
32
0: Overwrite (First K-Tile)1: Accumulate (Subsequent K-Tiles)
0x14
PPU_MULT
R/W
32
Quantization Multiplier (Fixed point)
0x18
PPU_SHIFT
R/W
32
Quantization Right Shift
0x1C
PPU_ZP
R/W
32
Output Zero Point
0x20
PPU_BIAS
R/W
32
Output Bias
0x24
OUTPUT_EN
R/W
32
1: Enable PPU output to stream0: Disable (Internal Accumulation only)


6. Known Issues & Watchlist (注意事项)
Output TLAST: 目前 output_buffer_ctrl.v 中的 axis_tlast 硬连线为 0。
Impact: 对于 AXI DMA，如果没有开启 TLAST 截断，通常没问题（按字节计数传输）。但如果需要 TLAST 包边界，需要在后续加入计数器逻辑。
Reset Timing: 必须先写 0x00 = 2 (释放复位) 再写 0x00 = 3 (启动)。如果同时拉高或顺序不对，Input Buffer 可能无法正确写入数据（因为 Write Pointer 复位依赖 rst_n）。
Config Consistency: Python 脚本生成的 config.mem 必须与 TB 中写入寄存器的值一致，否则 PPU 计算结果会全是 7f 或 80 (饱和)。

7. Phase 6 Roadmap (下一阶段计划)
我们即将进入 Phase 6: Real-World Verification & System Implementation。
Task 6.1: Real DeiT-Tiny Weights Verification (验证真实权重)
目前的测试使用的是随机数。我们需要：
从 PyTorch/ONNX 导出 DeiT-Tiny 的真实权重和输入（例如第一层 Patch Embedding 或 Attention QKV）。
编写 Python 转换脚本，将这些真实浮点/INT8 数据转换为我们的 .mem 格式。
运行 simulate_top.sh，确认硬件算出的结果与 PyTorch 结果一致（允许 +/- 1 的量化误差）。
目标: 证明加速器不仅能算对随机数，也能算对 Transformer。
Task 6.2: Vivado IP Packaging (IP 打包)
编写 package_ip.tcl 脚本。
定义 AXI-Lite 和 AXI-Stream 接口映射。
确保 Vivado 能够识别 Top Level 并综合通过。
Task 6.3: Block Design & PS Driver (BD 与 驱动)
在 Vivado 中搭建 Zynq PS + AXI DMA + DeiT Accelerator 的 Block Design。
编写 Jupyter Notebook (PYNQ) 驱动：
分配 CMA 内存 (Input/Output/Weights)。
配置寄存器 (0x00 - 0x24)。
启动 DMA 传输。
比较软硬运行时间。

致下一位接棒者 (Instructions for the next session):
你好。我是上一轮的 Architect。
所有的 RTL 代码都在 src/ 目录下，且已通过 Phase 5 验证。
请不要轻易修改 src/deit_core.v, global_controller.v, *buffer_ctrl.v 的核心逻辑，除非你有绝对的把握。当前的握手时序处于一种精妙的平衡状态。
你的首要任务是 Task 6.1。请按照我们的sop创建一个新的 Python 脚本 gen_real_weights.py，并给出能完成这个功能的tb文件和配套sh脚本，模拟一个真实的 $M=197, K=192, N=192$ (或更小块) 的计算任务，验证 Output Buffer 深度是否足够，以及多 Tile 累加是否在真实数据下依然精确。
祝好运。The foundation is solid. Build something amazing.

