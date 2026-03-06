工程蓝图：DeiT-Tiny on Zynq-7020 (PYNQ 极速原型路线)

项目名称: DeiT-Tiny HW/SW Co-design Architecture
执行环境: Zynq-7020 (正点原子领航者 V2) + PYNQ Linux
设计者: Google TPU Team / Principal AI Infra Architect
文档版本: v1.0 (Phase 6 HW/SW Integration)
日期: 2026-03-06

1. 架构愿景与执行策略 (Executive Summary)

本方案旨在通过 PYNQ 框架 (Python Productivity for Zynq)，在 Zynq-7020 平台上以极低的开发成本实现 DeiT-Tiny 的全量推理。

核心指导原则：

数据离线化 (Offline Pre-processing): PC 端承担所有“脏活累活”。PC 负责读取 PyTorch 模型、执行 PTQ 量化、将张量重排 (Reshape & Pad) 为底层 PL 期望的 64-bit 连续字节流，并生成 .bin 文件存入 SD 卡。

重计算下发 (Heavy-Compute Offloading): 所有的矩阵乘法 (GEMM) 及其附带的线性量化操作 (Bias, Scale, Shift)，无脑卸载至 PL 侧的 $12 \times 16$ 脉动阵列。

轻计算驻留 (Light-Compute Hosting): 所有的非线性操作 (LayerNorm, Softmax, GELU, ResAdd) 保留在 PS 侧，利用 Python/NumPy (底层调用 ARM NEON SIMD) 完成。

零拷贝通信 (Zero-copy I/O): 利用 PYNQ 的 pynq.allocate 分配连续物理内存 (CMA)，彻底消除 PS 与 PL 之间的内存拷贝开销。

2. DeiT-Tiny 网络结构与算子拆解 (Model Analysis & HW Mapping)

在编写驱动前，我们必须从体系结构角度精准剖析 DeiT-Tiny。

2.1 DeiT-Tiny 宏观参数

Patch Size: 16x16

Embedding Dim ($D$): 192

Heads ($H$): 3 (每头维度 $D_h = 64$)

Depth ($L$): 12 层

MLP Ratio: 4 (Hidden Dim = 768)

Sequence Length ($M$): $224 \times 224$ 图像拆分为 $14 \times 14 = 196$ 个 Patch，加上 1 个 Class Token。

$M = 197$ (推理时的核心维度)。

2.2 每一层 (Transformer Block) 的算子拆解与软硬分配

算子名称 (Operator)

输入尺寸

权重尺寸

输出尺寸

执行单元

功能描述与数据流

LayerNorm 1

[197, 192]

[192] (w/b)

[197, 192]

PS

计算均值方差，归一化。Python NumPy 直接计算。

QKV Proj (x3)

[197, 192]

[192, 192]

[197, 192]

PL

核心矩阵乘。$M=197, K=192, N=192$。

Attention Score

[197, 64]

[64, 197]

[197, 197]

PL

$Q \times K^T$。此时权重 $B$ 其实是 $K^T$。硬件视其为 $M=197, K=64, N=197$ 的 GEMM。

Scale & Softmax

[197, 197]

-

[197, 197]

PS

乘以 $1/\sqrt{64}$，按行 Softmax。

Attention Out

[197, 197]

[197, 64]

[197, 64]

PL

$Score \times V$。$M=197, K=197, N=64$。

Out Proj

[197, 192]

[192, 192]

[197, 192]

PL

多头拼接后的线性投影。

ResAdd 1

[197, 192]

-

[197, 192]

PS

残差连接：X + Attention(X)。

LayerNorm 2

[197, 192]

[192] (w/b)

[197, 192]

PS

MLP 前的归一化。

MLP FC1

[197, 192]

[192, 768]

[197, 768]

PL

升维映射。$M=197, K=192, N=768$。

GELU Act

[197, 768]

-

[197, 768]

PS

激活函数。可用 NumPy 逼近算法计算。

MLP FC2

[197, 768]

[768, 192]

[197, 192]

PL

降维映射。$M=197, K=768, N=192$。

ResAdd 2

[197, 192]

-

[197, 192]

PS

残差连接。

2.3 硬件填充边界分析 (Padding Bounds)

根据我们设定的脉动阵列尺寸 ($12 \times 16$)：

$M_{pad}$ 需为偶数：$197 \rightarrow \mathbf{198}$。

$K_{pad}$ 需为 12 倍数：192 是 12 的 16 倍，完美匹配，无需 Pad。768 是 12 的 64 倍，完美匹配。唯一需要 Pad 的是 Attention Score 时的 197 (补至 204) 和 64 (补至 72)。

$N_{pad}$ 需为 16 倍数：192 是 16 的 12 倍，完美匹配。768 是 16 的 48 倍，完美匹配。

架构师批注：DeiT-Tiny 的通道维度 (192, 768) 与我们的硬件设计 (12, 16) 发生了极度完美的化学反应，几乎没有计算资源的浪费。这意味着我们不需要传输大量无效的 0，带宽利用率将逼近 100%。

3. PC 侧数据预处理与 SD 卡打包 (Offline Pre-processing)

这一步在你的笔记本电脑 (PC) 上完成。我们将提供 Python 脚本，将 PyTorch 模型拆解并按照底层 AXI-Stream 的 64-bit 时序格式打包。

3.1 权重提取与量化逻辑 (Fake Quantization)

由于我们 PL 侧的 PPU 支持 INT32 累加 -> INT8 的线性量化（公式：Out = (Acc + Bias) * Mult >> Shift + ZP），PC 侧需要计算出每层的 Mult, Shift, ZP 和 Bias，并随同权重一起保存。

3.2 矩阵重排算法 (Matrix Packing Algorithm)

这是本节最核心的代码。硬件期望的是：

A 矩阵：每 K-Tile [M_pad, 12]，展平为字节流，按 8 字节 (64-bit) 打包。

B 矩阵：每 N-Tile, K-Tile [12, 16]，拆分为低 64 位和高 64 位。

import numpy as np
import math
import struct

def pack_matrix_A_to_bin(A_int8, filename):
    """
    将激活矩阵 A [M, K] 打包为 PL 端输入流格式
    """
    M, K = A_int8.shape
    M_pad = math.ceil(M / 2) * 2
    K_pad = math.ceil(K / 12) * 12
    
    # 补零
    A_padded = np.zeros((M_pad, K_pad), dtype=np.int8)
    A_padded[:M, :K] = A_int8
    
    K_tiles = K_pad // 12
    
    with open(filename, 'wb') as f:
        for k_idx in range(K_tiles):
            # 提取当前 K-Tile: 形状 [M_pad, 12]
            tile = A_padded[:, k_idx*12 : (k_idx+1)*12]
            
            # 展平为一维字节流 [M_pad * 12]
            flat_bytes = tile.flatten()
            
            # 补齐 8 字节对齐 (64-bit beat)
            # M_pad 必须为偶数，所以 M_pad * 12 一定是 24 的倍数，完美被 8 整除
            for i in range(0, len(flat_bytes), 8):
                # 提取 8 字节并组合成 64-bit 整数 (Little-Endian)
                chunk = flat_bytes[i:i+8]
                val64 = 0
                for byte_idx, b in enumerate(chunk):
                    # Python int8 转 uint8 处理负数
                    ubyte = int(b) & 0xFF
                    val64 |= (ubyte << (byte_idx * 8))
                
                # 写入 8 字节二进制 (unsigned long long)
                f.write(struct.pack('<Q', val64))

def pack_matrix_B_to_bin(B_int8, filename):
    """
    将权重矩阵 B [K, N] 打包为 PL 端权重流格式
    """
    K, N = B_int8.shape
    K_pad = math.ceil(K / 12) * 12
    N_pad = math.ceil(N / 16) * 16
    
    B_padded = np.zeros((K_pad, N_pad), dtype=np.int8)
    B_padded[:K, :N] = B_int8
    
    K_tiles = K_pad // 12
    N_tiles = N_pad // 16
    
    with open(filename, 'wb') as f:
        for n_idx in range(N_tiles):
            for k_idx in range(K_tiles):
                # 提取当前子块: 形状 [12, 16]
                tile = B_padded[k_idx*12:(k_idx+1)*12, n_idx*16:(n_idx+1)*16]
                
                for row in range(12):
                    # 提取一行 16 字节
                    row_bytes = tile[row, :]
                    
                    # 拆分：低 8 字节 (低 64 位), 高 8 字节 (高 64 位)
                    low_chunk = row_bytes[0:8]
                    high_chunk = row_bytes[8:16]
                    
                    val_low = sum((int(b)&0xFF) << (i*8) for i, b in enumerate(low_chunk))
                    val_high = sum((int(b)&0xFF) << (i*8) for i, b in enumerate(high_chunk))
                    
                    # 先发低 64 位，后发高 64 位
                    f.write(struct.pack('<Q', val_low))
                    f.write(struct.pack('<Q', val_high))


3.3 SD 卡目录结构

将预处理好的文件通过读卡器拷贝到正点原子板卡的 SD 卡中。挂载后目录结构如下：

/mnt/sdcard/
├── inputs/
│   ├── image_001_normalized.bin  # 测试用的一张预处理好并展平的图片特征
├── weights/
│   ├── layer0_q_proj.bin
│   ├── layer0_k_proj.bin
│   ├── layer0_v_proj.bin
│   ├── layer0_mlp_fc1.bin
│   └── ... 
└── config/
    ├── ppu_params.json   # 存放各层的 mult, shift, zp, bias


4. PS 侧驱动架构：DeiT_Accelerator 类 (PYNQ)

在 Zynq 板卡的 Jupyter Notebook 中运行。这段代码是硬件加速器最直接的“操作员”。

由于硬件接口采用 A 和 B 分时复用同一个 AXI-Stream 的紧凑设计，我们在 hw_gemm 中必须严格遵守 DMA 发送顺序：先送 A，给 Start 脉冲，再送 B。

4.1 硬件控制类封装

import pynq
from pynq import Overlay
import numpy as np
import time

class DeiTTinyAccelerator:
    def __init__(self, bitstream_path):
        # 1. 加载 Bitstream
        self.overlay = Overlay(bitstream_path)
        self.axi_ctrl = self.overlay.axi_lite_control_0 # 对应 Vivado 中的 IP 名字
        self.dma = self.overlay.axi_dma_0
        
        # 寄存器地址偏移 (遵循 Interface Contract)
        self.REG_CTRL      = 0x00
        self.REG_STATUS    = 0x04
        self.REG_SEQ_LEN   = 0x08
        self.REG_ACC_MODE  = 0x0C
        self.REG_PPU_MULT  = 0x14
        self.REG_PPU_SHIFT = 0x18
        self.REG_PPU_ZP    = 0x1C
        self.REG_PPU_BIAS  = 0x20
        self.REG_OUTPUT_EN = 0x24
        
        self.soft_reset()
        print("Hardware Initialized. Status:", hex(self.axi_ctrl.read(self.REG_STATUS)))

    def soft_reset(self):
        """强制软复位并释放"""
        self.axi_ctrl.write(self.REG_CTRL, 0x00) # [1]=0, [0]=0
        time.sleep(0.01)
        self.axi_ctrl.write(self.REG_CTRL, 0x02) # [1]=1, [0]=0
        
        # 等待 IDLE
        while (self.axi_ctrl.read(self.REG_STATUS) & 0x02) == 0:
            pass

    def config_ppu(self, mult, shift, zp, bias):
        self.axi_ctrl.write(self.REG_PPU_MULT, int(mult))
        self.axi_ctrl.write(self.REG_PPU_SHIFT, int(shift))
        self.axi_ctrl.write(self.REG_PPU_ZP, int(zp))
        self.axi_ctrl.write(self.REG_PPU_BIAS, int(bias))

    def hw_gemm(self, A_cma, B_cma, C_cma, M, K, N, ppu_params):
        """
        执行 C = A * B，全程零拷贝。
        A_cma, B_cma, C_cma 必须是通过 pynq.allocate 分配的 1D uint64_t 连续内存。
        """
        M_pad = (M + 1) // 2 * 2
        K_tiles = (K + 11) // 12
        N_tiles = (N + 15) // 16
        
        # 配置序列长度 (硬件约定写入 M_pad - 1)
        self.axi_ctrl.write(self.REG_SEQ_LEN, M_pad - 1)
        self.config_ppu(**ppu_params)
        
        # 计算各种 tile 的 beat 数量 (8 字节为一个 beat)
        beats_a_per_k_tile = (M_pad * 12) // 8
        beats_b_per_tile = (12 * 16) // 8  # = 24
        beats_c_per_n_tile = (M_pad * 16) // 8
        
        for n_idx in range(N_tiles):
            for k_idx in range(K_tiles):
                # 1. 设置累加模式
                acc_mode = 0 if k_idx == 0 else 1
                self.axi_ctrl.write(self.REG_ACC_MODE, acc_mode)
                
                # 2. 设置输出使能 (仅最后一个 K 块时输出)
                out_en = 1 if k_idx == K_tiles - 1 else 0
                self.axi_ctrl.write(self.REG_OUTPUT_EN, out_en)
                
                # 3. 预发输入 A_tile
                # 由于 A 和 B 共用 DMA Send 通道，必须依靠切片保证发送顺序
                a_offset = k_idx * beats_a_per_k_tile
                A_slice = A_cma[a_offset : a_offset + beats_a_per_k_tile]
                
                self.dma.sendchannel.transfer(A_slice)
                self.dma.sendchannel.wait() # 等待 A 传输进入硬件 Input Buffer
                
                # 4. 触发计算 (发脉冲)
                # 此时硬件的 core_weight_dma_req 会拉高，引导 AXI 路由器指向 Weight Buffer
                self.axi_ctrl.write(self.REG_CTRL, 0x03) # Start=1, Rst_n=1
                self.axi_ctrl.write(self.REG_CTRL, 0x02) # 手动拉低 Start
                
                # 5. 立即发送权重 B_tile
                b_offset = (n_idx * K_tiles + k_idx) * beats_b_per_tile
                B_slice = B_cma[b_offset : b_offset + beats_b_per_tile]
                
                self.dma.sendchannel.transfer(B_slice)
                self.dma.sendchannel.wait()
                
                # 6. 等待硬件核心计算完成 (Polling Done Bit)
                while (self.axi_ctrl.read(self.REG_STATUS) & 0x01) == 0:
                    pass
                # 清除 Done 标志 (W1C)
                self.axi_ctrl.write(self.REG_STATUS, 0x01)
                
                # 7. 接收输出 (如果这是最后一个 K-Tile)
                if out_en == 1:
                    c_offset = n_idx * beats_c_per_n_tile
                    C_slice = C_cma[c_offset : c_offset + beats_c_per_n_tile]
                    
                    self.dma.recvchannel.transfer(C_slice)
                    self.dma.recvchannel.wait()


4.2 PS 侧非线性算子库 (Software Operators)

在 PYNQ 环境下，我们使用 NumPy，其底层链接了 OpenBLAS 并在 ARM 处理器上使用了 NEON 向量指令集，性能远超市面上的手写 C++ for 循环。

import numpy as np

def ps_layer_norm(x, gamma, beta, eps=1e-5):
    """
    PS 端 LayerNorm 算子。
    x: [M, D] 维特征矩阵
    """
    mean = np.mean(x, axis=-1, keepdims=True)
    var = np.var(x, axis=-1, keepdims=True)
    x_norm = (x - mean) / np.sqrt(var + eps)
    return gamma * x_norm + beta

def ps_softmax(x, axis=-1):
    """PS 端 Softmax 算子，防止溢出"""
    e_x = np.exp(x - np.max(x, axis=axis, keepdims=True))
    return e_x / np.sum(e_x, axis=axis, keepdims=True)

def ps_gelu(x):
    """PS 端 GELU 近似算子 (Fast GELU)"""
    return 0.5 * x * (1 + np.tanh(math.sqrt(2 / math.pi) * (x + 0.044715 * np.power(x, 3))))


5. 端到端数据流演示 (End-to-End Walkthrough)

让我们完整模拟一遍 Transformer 第一层的执行逻辑。在这个逻辑中，你可以看到数据是如何在 PS (内存/CPU) 和 PL (FPGA 计算核心) 之间高效穿梭的。

# ==========================================
# 初始化阶段 (执行一次)
# ==========================================
accel = DeiTTinyAccelerator("design_1.bit")

# 分配连续物理内存 CMA (Zero-copy)
# M=198 (padded), K=192, N=192
# A 的尺寸: M_pad * K_pad 字节 -> 198 * 192 = 38016 bytes -> 4752 uint64
A_cma = pynq.allocate(shape=(4752,), dtype=np.uint64)
# Q/K/V Weight 尺寸: K_pad * N_pad 字节 -> 192 * 192 = 36864 bytes -> 4608 uint64
Wq_cma = pynq.allocate(shape=(4608,), dtype=np.uint64)
Wk_cma = pynq.allocate(shape=(4608,), dtype=np.uint64)
Wv_cma = pynq.allocate(shape=(4608,), dtype=np.uint64)

# C 的尺寸: M_pad * N_pad 字节 -> 198 * 192 = 38016 bytes -> 4752 uint64
C_q_cma = pynq.allocate(shape=(4752,), dtype=np.uint64)
C_k_cma = pynq.allocate(shape=(4752,), dtype=np.uint64)
C_v_cma = pynq.allocate(shape=(4752,), dtype=np.uint64)

# 假设从 SD 卡加载数据并填充到 CMA 中 (省略具体读取二进制的代码)
# load_bin_to_cma("/mnt/sdcard/weights/layer0_q.bin", Wq_cma)
# load_bin_to_cma("/mnt/sdcard/inputs/image_features.bin", A_cma)

# ==========================================
# 在线推理阶段 (实时循环)
# ==========================================
import time

# 记录开始时间
start_time = time.time()

# 1. PS 端 LayerNorm (需要将 A_cma 解包为 float32 numpy)
A_float = unpack_cma_to_float(A_cma, M=197, K=192)
A_norm = ps_layer_norm(A_float, gamma_l1, beta_l1)
# 重新量化打包回 A_cma
pack_float_to_cma(A_norm, A_cma)

# 2. PL 端 QKV 投影 (并行硬件加速)
# 计算 Q
accel.hw_gemm(A_cma, Wq_cma, C_q_cma, M=197, K=192, N=192, ppu_params=q_ppu)
# 计算 K
accel.hw_gemm(A_cma, Wk_cma, C_k_cma, M=197, K=192, N=192, ppu_params=k_ppu)
# 计算 V
accel.hw_gemm(A_cma, Wv_cma, C_v_cma, M=197, K=192, N=192, ppu_params=v_ppu)

# 3. PS 端 Attention Score 计算
# 从 CMA 解包拿到 Q, K
Q = unpack_cma_to_float(C_q_cma, M=197, K=192)
K = unpack_cma_to_float(C_k_cma, M=197, K=192)
# Reshape 为多头: [197, 3, 64] -> 转置为 [3, 197, 64]
Q_heads = Q.reshape(197, 3, 64).transpose(1, 0, 2)
K_heads = K.reshape(197, 3, 64).transpose(1, 0, 2)

# PS 端计算 Q * K^T (由于矩阵较小 [197, 64]，可以直接让 ARM 算，
# 或者如果要在 PL 算，需要再次重排打包)
Scores = np.matmul(Q_heads, K_heads.transpose(0, 2, 1)) / np.sqrt(64)
Attention = ps_softmax(Scores, axis=-1)

# 4. Attention * V 并在 PS 端 ResAdd
# ... 类似逻辑

end_time = time.time()
print(f"Layer 0 Latency: {(end_time - start_time) * 1000:.2f} ms")


6. 进阶优化路线 (Path to Production Optimization)

当前提供的架构是“极速原型”的最佳实践，它能让你在几小时内打通从 SD 卡读取到矩阵乘法加速的全流程。当跑通基准测试后，为了进一步提升并发性能，你需要考虑以下优化：

异步 DMA 调用 (Asynchronous PYNQ DMA)：
当前的 dma.wait() 是阻塞的 (Blocking)，意味着当 PL 在进行矩阵运算时，PS 的 ARM 核在原地傻等。真正的工业级做法是利用 Python 的 asyncio。让 DMA 在后台工作，在此期间 PS 的 CPU 提前计算下一层的 LayerNorm。

Double Buffering (双缓冲/Ping-Pong Memory)：
分配两组 A_cma 和 C_cma。当硬件在处理第一块数据时，CPU 正在把计算好的 LayerNorm 结果打包到第二块内存中，消除数据准备的停顿。

Cache 控制策略：
PYNQ 底层虽然通过 xlnk 处理了连续内存的 Cache 问题，但在极端高频的读写交互中，频繁的 Cache Invalidate 仍会耗时。最终的终极形态是绕过 Python 操作系统级抽象，通过 C++ udmabuf 进行深度的 Cache 命中优化。

请开始执行！ 你可以立刻按照第三节的 Python 打包代码，在你个人的电脑上生成对应的 .bin 测试文件存入 SD 卡，然后在 PYNQ Jupyter 里面复现第四节的代码。我随时为你待命，解决 DMA 传输中的任何诡异现象。