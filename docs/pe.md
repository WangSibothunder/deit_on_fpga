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
