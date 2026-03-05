# PL 接口汇报：PS 侧如何驱动矩阵乘法

本文档说明 PS 侧如何通过 AXI-Lite + AXI-Stream 与 PL 侧 `deit_accelerator_top` 通信，完成矩阵乘法与量化输出。内容基于当前 RTL 实现与测试流程，重点是**正确的数据布局、寄存器配置、启动顺序与输出读取**。

---

**PL 顶层接口概览**

接口类型：
- AXI4-Lite：控制与配置寄存器
- AXI-Stream 输入：**A(输入矩阵) 与 B(权重矩阵) 共用一个流**
- AXI-Stream 输出：PPU 量化后的输出流

关键信号行为：
- `axis_in_tready` 恒为 1，不提供背压
- `axis_out_tvalid` 由 PL 侧输出 FIFO 产生，`axis_out_tlast` 恒为 0

---

**寄存器映射（AXI-Lite）**

基地址由 Vivado Address Editor 分配，以下是相对偏移：

| Offset | 名称 | 访问 | 位域 | 说明 |
|---|---|---|---|---|
| 0x00 | CTRL_REG | RW | [0] AP_START | 写 1 触发单周期启动脉冲（自动清零） |
| 0x00 | CTRL_REG | RW | [1] SOFT_RST_N | 0: 复位, 1: 释放复位 |
| 0x04 | STATUS_REG | RW | [0] AP_DONE | Done 粘滞位，写 1 清零（W1C） |
| 0x04 | STATUS_REG | RO | [1] AP_IDLE | 空闲状态指示 |
| 0x08 | CFG_K_DIM | RW | [31:0] | **序列长度配置**，需写 `M_PAD - 1` |
| 0x0C | CFG_ACC_MODE | RW | [0] | 0: 覆写模式，1: 累加模式 |
| 0x10 | VERSION | RO | [31:0] | 版本号（0x20260117） |
| 0x14 | PPU_MULT | RW | [15:0] | 量化乘法系数 |
| 0x18 | PPU_SHIFT | RW | [4:0] | 量化右移 |
| 0x1C | PPU_ZP | RW | [7:0] | 量化零点 |
| 0x20 | PPU_BIAS | RW | [31:0] | 量化偏置 |
| 0x24 | OUTPUT_EN | RW | [0] | 1: 使能输出，0: 不输出 |

**关键语义**
- `CFG_K_DIM` 实际用于**序列计数**，硬件比较条件为 `cnt_seq >= cfg_seq_len - 1`，因此必须写 `M_PAD - 1`。
- `AP_DONE` 为粘滞位，必须写 1 清零，否则下一次任务可能检测到旧 Done。

---

**矩阵维度与补零规则**

硬件采用 12x16 脉动阵列，必须补零到如下边界：
- `M_PAD`: 向上补到偶数（M 为序列长度）
- `K_PAD`: 向上补到 12 的倍数
- `N_PAD`: 向上补到 16 的倍数

推荐约束：
- `M_PAD <= 256`（输入 Buffer 深度 256 行）
- `M_PAD <= 256`（输出 FIFO 深度 256 行）

---

**AXI-Stream 数据格式**

1) 输入矩阵 A（AXI-Stream 输入）

单位：**K tile**。每个 K tile 为 `M_PAD x 12`，按行优先展开。

- 字节顺序：先行后列（row-major），每行 12 字节
- 打包为 64-bit：每 8 字节组成一个 beat
- 字节到 64-bit 映射：第 1 个字节放在 `tdata[7:0]`，第 8 个字节在 `tdata[63:56]`
- 每个 K tile 的 beat 数：`M_PAD * 12 / 8 = M_PAD * 3 / 2`

2) 权重矩阵 B（AXI-Stream 输入）

单位：**(N tile, K tile)**。每个 tile 为 `12 x 16`。

- 每行 16 字节 -> 128-bit
- 发送顺序：**低 64 位先发，高 64 位后发**
- 每个 tile 的 beat 数：`12 * 2 = 24`

3) 输出矩阵 C（AXI-Stream 输出）

单位：**N tile**。每 tile 为 `M_PAD x 16`。

- 每行 16 字节 -> 128-bit
- 输出顺序：**低 64 位先出，高 64 位后出**
- 每个 N tile 的 beat 数：`M_PAD * 2`
- `axis_out_tlast` 恒为 0，PS 必须按期望长度收完

---

**PS 侧推荐执行流程（单次任务）**

**步骤 0：准备数据**
- 根据 M/K/N 计算 `M_PAD/K_PAD/N_PAD`。
- 按上面的格式组织 A、B，并在 K/N 维度补零。

**步骤 1：软复位**
- 写 `CTRL_REG[1]=0`（强制复位），等待若干周期
- 写 `CTRL_REG[1]=1`（释放复位）
- 读 `STATUS_REG[1]=1` 确认 IDLE

**步骤 2：配置寄存器**
- 写 `CFG_K_DIM = M_PAD - 1`
- 写 PPU 参数寄存器（MULT/SHIFT/ZP/BIAS）

**步骤 3：按 tile 运行**
对每个 N tile，执行以下 K tile 循环：

1. 写 `CFG_ACC_MODE`
   - K tile=0: 写 0（覆盖）
   - K tile>0: 写 1（累加）
2. 写 `OUTPUT_EN`
   - 仅最后一个 K tile 写 1
   - 其它 K tile 写 0
3. **预加载 A tile**
   - 在 `AP_START` 之前发送该 K tile 的输入流
4. 写 `AP_START`（CTRL_REG bit0 写 1）
5. **立即发送权重 B tile**
   - 权重数据必须在 `core_weight_dma_req` 高电平期间送入
   - 推荐：`AP_START` 后立刻启动权重 DMA，保证在固定窗口内完成
6. 轮询 `STATUS_REG[0]` 等待 Done
7. 写 1 清零 `STATUS_REG[0]`
8. 若该 K tile 为最后一个 K tile：
   - 读取 `M_PAD*2` 个输出 beat

---

**注意事项**

- 输入与权重共用 AXI-Stream 输入口，**必须严格按流程分时发送**。
- `axis_in_tready` 恒为 1，不会背压，PS 必须自行保证数据量准确。
- `axis_out_tlast` 恒为 0，**输出 DMA 长度必须固定计算**。
- 输出仅在 `OUTPUT_EN=1` 时产生，故应只在最后一个 K tile 开启输出。
- Done 为粘滞位，必须写 1 清零，否则下一次任务可能误判 Done。

---

**典型参数示例**

- 任务：`M=67, K=93, N=67`
- 计算：`M_PAD=68, K_PAD=96, N_PAD=80`
- K tile 数 = 96 / 12 = 8
- N tile 数 = 80 / 16 = 5
- 输入每 K tile beat 数 = 68 * 3 / 2 = 102
- 权重每 tile beat 数 = 24
- 输出每 N tile beat 数 = 68 * 2 = 136

---

如果需要，我可以再补充：
- PS 侧 C/Python 驱动模板
- DMA descriptor 组织方式
- 实机测量的时序窗口建议
