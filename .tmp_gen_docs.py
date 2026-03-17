from pathlib import Path

# -----------------------------
# Helper: remove old sections
# -----------------------------

def strip_sections(text: str) -> str:
    lines = text.splitlines()
    out = []
    skip = False
    for line in lines:
        if line.startswith('## '):
            title = line[3:].strip()
            is_q = (len(title) >= 3 and set(title) == {'?'})
            if ('局部数据流动' in title) or ('状态机控制图' in title) or is_q:
                skip = True
                continue
            else:
                skip = False
        if not skip:
            out.append(line)
    return '\n'.join(out).rstrip() + '\n'

# -----------------------------
# Local dataflow bullets
# -----------------------------

dataflow = {
    'accumulator_bank': [
        'in_psum_vec 分片成 16 列，分别送入 single_column_bank。',
        'addr / wr_en / acc_mode 广播到所有列，保证同地址对齐读改写。',
        '单列 Bank 采用 RMW 流程并写穿透旁路，写入拍即可输出新值。',
        'out_acc_vec 将 16 列输出重新拼接，供 PPU 或后级消费。',
        '仿真初始化清零 RAM，避免未写区域的 X 传播。'
    ],
    'axi_lite_control': [
        'AXI-Lite 写通道接收 awaddr + wdata，组合成寄存器写入请求。',
        'wstrb 按字节选择性写入，支持字段级覆盖。',
        '读通道根据 araddr 选择寄存器并返回 rdata。',
        '寄存器输出驱动 ap_start 与各类 cfg_*，直接控制 Core/PPU/Buffer。',
        '状态与调试计数回写到读通道，供 PS 侧轮询。',
        'bresp / rresp 固定为 OKAY，协议路径保持简单。'
    ],
    'deit_accelerator_top': [
        'AXI-Lite 配置进入 deit_core、PPU 与各 Buffer 控制器。',
        'AXI-Stream Input 进入 input_buffer_ctrl，Weight 进入 weight_buffer_ctrl。',
        'deit_core 产生权重加载、输入流使能与 drain 控制。',
        'systolic_array 产生 psum，经 accumulator_bank 与 ppu 量化。',
        'output_buffer_ctrl 将 128b 结果拆分为 64b AXI-Stream 输出。',
        '全局调试信号在 top 汇聚，便于 PS 侧观察。'
    ],
    'deit_core': [
        'global_controller 生成权重加载、输入流使能与 drain 三类控制。',
        'in_act_vec 经 Input Skew 形成对角线数据流，匹配阵列节拍。',
        'in_weight_vec 延迟对齐后进入 systolic_array。',
        'systolic_array 输出 psum，Output Deskew 补偿列级延迟。',
        'accumulator_bank 根据 acc_mode 覆盖或累加，送入 PPU。',
        'valid_delay_line 与 i_input_valid 保证写入与输出对齐。'
    ],
    'global_controller': [
        'ap_start 触发状态机进入 LOAD_W，cfg_seq_len 决定 COMPUTE 周期。',
        'ctrl_weight_dma_req 指示 PS/DMA 拉权重，i_weight_dma_beat 计数。',
        'ctrl_weight_load_en 打开权重装载窗口并驱动 row_load_en。',
        'ctrl_input_stream_en 允许输入流读取，i_input_valid 用于对齐。',
        'ctrl_drain_en 在计算结束后保持输出 drain。',
        'ap_done 在 DONE 周期拉高，ap_idle 在 IDLE 维持高电平。'
    ],
    'input_buffer_ctrl': [
        's_axis_tdata 进入 3×64b→2×96b Gearbox，gb_state 轮转拼接。',
        'ram_wen 与 wr_addr_pipe 对齐后写入当前 bank。',
        'i_bank_swap 触发 bank_sel 翻转并清空读写指针。',
        'i_rd_en 发起读请求，o_dat_valid 延迟 1 拍输出。',
        'o_array_vec 作为 deit_core 的输入激活向量。',
        's_axis_tready 恒为 1，帧边界由 i_bank_swap 控制。'
    ],
    'output_buffer_ctrl': [
        'i_data/i_valid 写入 128b FIFO，o_full 反馈上游背压。',
        '读端 FSM 从 FIFO 取 128b，分两拍输出 64b。',
        'axis_tready 握手控制 beat 递增与 rd_ptr 更新。',
        'i_cfg_seq_len 映射为 frame_beats=seq_len*2，驱动 tlast。',
        'frame_active 在帧内保持稳定，帧尾回到 IDLE。',
        'dbg_obuf_* 指针用于定位丢包与背压问题。'
    ],
    'pe': [
        '每个 PE 接收 in_act 与 in_weight，组合乘法得到局部乘积。',
        '乘积与 in_psum 累加形成 out_psum。',
        '激活向下传递、权重向右传递，维持阵列流动。',
        'en_compute 控制计算使能，复位清零内部寄存器。'
    ],
    'ppu': [
        '输入 16×INT32 psum，逐 lane 加 bias。',
        '乘以 cfg_mult 并右移 cfg_shift 完成缩放。',
        '加 cfg_zp 进行零点偏移，饱和截断到 INT8。',
        '输出寄存器打拍，o_valid 延迟 1 拍。',
        '结果拼接成 128b 写入输出缓冲。'
    ],
    'single_column_bank': [
        'mem[addr] 异步读出 old_val 参与计算。',
        'acc_mode 决定覆盖或累加，生成 next_val。',
        'wr_en 高时同步写回 next_val。',
        '写穿透旁路保证输出与写入同拍一致。',
        '仿真初始化清零内存，避免 X 传播。'
    ],
    'systolic_array': [
        'row_load_en 按行加载权重到 PE 行寄存器。',
        'in_act_vec 经 Input Skew 形成对角线数据流。',
        '每拍完成乘加，psum 沿阵列流动。',
        'out_psum_vec 为列输出，延迟随列号递增。',
        'en_compute 允许暂停计算并保持阵列状态。'
    ],
    'weight_buffer_ctrl': [
        's_axis_tdata 64b 进入 Gearbox，2 beat 拼成 128b。',
        'ram_wen 写入当前 bank，wr_addr_pipe 与数据对齐。',
        'i_bank_swap 翻转 bank 并清零 wr_ptr/gb_cnt。',
        'i_weight_load_en 触发读端，o_dat_valid 延迟 2 拍。',
        'lookahead 读地址保证 Data0,Data0,Data1 对齐阵列。',
        'o_weight_vec 输出到 core 行加载链路。'
    ]
}

fsm_diagrams = {
    'input_buffer_ctrl': """stateDiagram-v2\n    [*] --> GB0\n    GB0 --> GB1: s_axis_tvalid\n    GB1 --> GB2: s_axis_tvalid\n    GB2 --> GB0: s_axis_tvalid\n    GB0 --> GB0: i_bank_swap\n    GB1 --> GB0: i_bank_swap\n    GB2 --> GB0: i_bank_swap\n""",
    'output_buffer_ctrl': """stateDiagram-v2\n    [*] --> IDLE\n    IDLE --> HALF0: !empty\n    HALF0 --> HALF1: axis_tvalid && axis_tready\n    HALF1 --> IDLE: axis_tvalid && axis_tready\n""",
    'global_controller': """stateDiagram-v2\n    [*] --> IDLE\n    IDLE --> LOAD_W: ap_start\n    LOAD_W --> COMPUTE: cnt_wload >= WEIGHT_ROWS\n    COMPUTE --> DRAIN: cnt_seq >= cfg_seq_len-1\n    DRAIN --> DONE: cnt_drain >= LATENCY-1\n    DONE --> IDLE: 1\n"""
}

# -----------------------------
# Update each module doc
# -----------------------------

for mod, bullets in dataflow.items():
    p = Path('docs') / f'{mod}.md'
    if not p.exists():
        continue
    text = p.read_text(encoding='utf-8')
    text = strip_sections(text)
    text = text.rstrip() + '\n\n## 局部数据流动\n'
    for b in bullets:
        text += f'- {b}\n'
    if mod in fsm_diagrams:
        text += '\n## 状态机控制图\n```mermaid\n' + fsm_diagrams[mod].rstrip() + '\n```\n'
    p.write_text(text, encoding='utf-8')

# -----------------------------
# Generate PL_RTL_Project_Spec
# -----------------------------

intro = """# PL 侧 RTL 项目总说明书 (DeiT 加速器, 完整版)

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
"""

module_order = [
    'accumulator_bank',
    'axi_lite_control',
    'deit_accelerator_top',
    'deit_core',
    'global_controller',
    'input_buffer_ctrl',
    'output_buffer_ctrl',
    'pe',
    'ppu',
    'single_column_bank',
    'systolic_array',
    'weight_buffer_ctrl',
]

module_titles = {
    'accumulator_bank': 'accumulator_bank',
    'axi_lite_control': 'axi_lite_control',
    'deit_accelerator_top': 'deit_accelerator_top',
    'deit_core': 'deit_core',
    'global_controller': 'global_controller',
    'input_buffer_ctrl': 'input_buffer_ctrl',
    'output_buffer_ctrl': 'output_buffer_ctrl',
    'pe': 'pe',
    'ppu': 'ppu',
    'single_column_bank': 'single_column_bank',
    'systolic_array': 'systolic_array',
    'weight_buffer_ctrl': 'weight_buffer_ctrl',
}

content = [intro]
for mod in module_order:
    p = Path('docs') / f'{mod}.md'
    if not p.exists():
        continue
    content.append(f'### 2.X 模块：{module_titles[mod]}\n')
    content.append(p.read_text(encoding='utf-8').rstrip())
    content.append('\n')

content.append("""## 3. 时序对齐与连线总结
- 输入侧：Input Skew 使行数据形成对角线流，与 row_load_en 的加载节拍匹配。
- 权重侧：Gearbox + 对齐寄存器消除 valid 与数据相位差。
- 输出侧：Output Deskew 与 valid_delay_line 保证列输出对齐与写入节拍一致。
- 缓冲侧：Ping-Pong Bank 在 bank_swap 时切换读写角色，实现双缓冲并行。

## 4. 结论
该 PL 侧 RTL 工程通过“控制-缓冲-阵列”的分层设计，将 DeiT 的主干矩阵运算拆解为可验证、可复用的模块。全局控制 FSM 清晰划分加载/计算/排空阶段，局部模块通过 Gearbox、Skew/Deskew、RMW 累加与 PPU 量化实现数据对齐与格式转换。配合 PS 侧 DMA 与双缓冲策略，可在较低控制复杂度下获得持续的阵列利用率，并在工程上保持可维护性与可扩展性。
""")

spec_text = '\n'.join(content).rstrip() + '\n'
Path('docs/PL_RTL_Project_Spec.md').write_text(spec_text, encoding='utf-8-sig')

# -----------------------------
# README files
# -----------------------------

readme_en = """# DeiT on FPGA (PL/PS Co-Design)

This repository implements a DeiT inference accelerator on FPGA. The PL side provides a systolic-array-based matrix engine with input/weight/output buffers, while the PS side handles DMA, configuration, and post-processing. The RTL is documented in detail and aligned with module-level specifications.

## Highlights
- Systolic array compute core with explicit timing alignment (Input Skew / Output Deskew)
- Ping-pong buffering for input/weight to overlap load and compute
- PPU quantization (bias/scale/shift/zero-point) producing INT8 output
- AXI-Lite control plane and AXI-Stream data plane

## Architecture Overview
- Control: PS writes registers through AXI-Lite to configure the accelerator.
- Data: PS streams input/weight through AXI DMA into PL buffers.
- Compute: deit_core orchestrates loading, compute, and drain phases.
- Output: results are quantized and streamed back to DDR via AXI DMA.

## Repository Structure
- `src/rtl`: PL RTL modules
- `docs`: Module specs and project-level documentation
- `ps/python`: PS-side python utilities and inference scripts
- `ps/notebooks`: PYNQ notebooks for validation and profiling
- `src/tb`: Testbenches (if used)

## Documentation
- `docs/PL_RTL_Project_Spec.md`: Full project spec with dataflow and diagrams
- `docs/input_buffer_ctrl.md`: Input buffer spec (includes FSM diagram)
- `docs/weight_buffer_ctrl.md`: Weight buffer spec
- `docs/output_buffer_ctrl.md`: Output buffer spec (includes FSM diagram)
- Other module specs are in `docs/`

## Running (PS side)
Example entry point for PYNQ:
```bash
python ps/python/deit_infer_pynq_v2.py
```

## Notes
- This update focuses on documentation and specification completeness.
- Tests were not run as part of this documentation update.
"""

readme_cn = """# DeiT on FPGA（PL/PS 协同设计）

本仓库实现了 DeiT 推理的 FPGA 加速器。PL 侧提供脉动阵列矩阵计算与多级缓冲，PS 侧完成 DMA、配置与后处理。RTL 与规格书对齐，方便归档与复现。

## 亮点
- 脉动阵列计算核心，配套 Input Skew / Output Deskew 时序对齐
- 输入/权重双缓冲（Ping-Pong）实现加载与计算重叠
- PPU 量化（bias/scale/shift/zero-point）输出 INT8
- AXI-Lite 控制面 + AXI-Stream 数据面

## 架构概览
- 控制路径：PS 通过 AXI-Lite 配置寄存器并启动计算
- 数据路径：PS 使用 AXI DMA 将输入/权重流送入 PL 缓冲
- 计算路径：deit_core 协调加载/计算/排空阶段
- 输出路径：量化结果通过 AXI DMA 写回 DDR

## 目录结构
- `src/rtl`: PL 侧 RTL 模块
- `docs`: 模块规格书与项目级说明书
- `ps/python`: PS 侧 Python 工具与推理脚本
- `ps/notebooks`: PYNQ 验证与调试 Notebook
- `src/tb`: 仿真测试平台（如使用）

## 规格书与文档
- `docs/PL_RTL_Project_Spec.md`: 项目总规格书，含全局/局部数据流与图示
- `docs/input_buffer_ctrl.md`: 输入缓冲规格书（含 FSM 图）
- `docs/output_buffer_ctrl.md`: 输出缓冲规格书（含 FSM 图）
- 其他模块规格书见 `docs/`

## 运行（PS 侧）
PYNQ 推理入口示例：
```bash
python ps/python/deit_infer_pynq_v2.py
```

## 说明
- 本次更新主要完善文档与规格书。
- 未执行测试（仅文档变更）。
"""

Path('README.md').write_text(readme_en, encoding='utf-8')
Path('README_CN.md').write_text(readme_cn, encoding='utf-8')

print('docs updated')
