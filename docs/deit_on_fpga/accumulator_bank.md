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
