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
