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
