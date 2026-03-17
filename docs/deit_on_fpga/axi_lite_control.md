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
