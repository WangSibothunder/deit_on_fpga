# DeiT on FPGA（PL/PS 协同设计）

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
