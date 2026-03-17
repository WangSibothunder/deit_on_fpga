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
