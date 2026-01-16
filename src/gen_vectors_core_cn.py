import numpy as np
import os

# ==============================================================================
# 1. 实验配置
# ==============================================================================
# 目标：验证 A(32x24) * B(24x32) = C(32x32)
# M = Sequence Length (序列长度/时间步)
# K = Input Channel (输入特征维度)
# N = Output Channel (输出特征维度)
M_DIM = 32
K_DIM = 24
N_DIM = 32

# 硬件核心参数 (不可修改)
# 这是一个 12行 x 16列 的脉动阵列
ARRAY_ROW = 12 
ARRAY_COL = 16 

OUT_DIR = "src/test_data_core"
if not os.path.exists(OUT_DIR):
    os.makedirs(OUT_DIR)

def to_hex(val, width):
    """转 Hex 辅助函数，处理负数补码"""
    val = int(val)
    if val < 0:
        val = (1 << width) + val
    return f"{val:0{width//4}x}"

def generate_core_vectors():
    print(f"=== [Python] 开始生成测试向量 V3 ===")
    print(f"    矩阵规模: A[{M_DIM}x{K_DIM}] * B[{K_DIM}x{N_DIM}]")
    print(f"    硬件阵列: {ARRAY_ROW}行 x {ARRAY_COL}列")

    # 1. 生成随机源数据 (INT8)
    # 使用 [-5, 5] 范围，确保结果可读且不易溢出
    mat_a = np.random.randint(-5, 5, size=(M_DIM, K_DIM), dtype=np.int8)
    mat_b = np.random.randint(-5, 5, size=(K_DIM, N_DIM), dtype=np.int8)

    # 2. 计算标准答案 (Golden)
    mat_c_golden = np.matmul(mat_a.astype(np.int32), mat_b.astype(np.int32))

    # 3. 计算切分数量
    # K 维度切分: 24 / 12 = 2 块
    # N 维度切分: 32 / 16 = 2 块
    num_k_tiles = K_DIM // ARRAY_ROW
    num_n_tiles = N_DIM // ARRAY_COL
    
    print(f"    [切分策略] K方向: {num_k_tiles} 块, N方向: {num_n_tiles} 块")

    # --------------------------------------------------------------------------
    # 4. 生成输入矩阵 A 的切片文件 (Input Files)
    # --------------------------------------------------------------------------
    # 逻辑: A 矩阵只需要按 K 维度切分。M 维度对应时间步，是一次流完的。
    for k in range(num_k_tiles):
        filename = f"{OUT_DIR}/input_k{k}.mem"
        
        # 切片范围: 例如 k=0 -> col 0..11; k=1 -> col 12..23
        col_start = k * ARRAY_ROW
        col_end   = col_start + ARRAY_ROW
        sub_a = mat_a[:, col_start:col_end] # Shape: [32, 12]

        with open(filename, "w") as f:
            for t in range(M_DIM): # 遍历 32 个时刻
                # 拼接 12 个数，每个 8bit。Row 11 在高位。
                line_hex = ""
                for r in range(ARRAY_ROW - 1, -1, -1):
                    line_hex += to_hex(sub_a[t, r], 8)
                f.write(line_hex + "\n")
        print(f"    -> 生成输入: {filename}")

    # --------------------------------------------------------------------------
    # 5. 生成权重矩阵 B 的切片文件 (Weight Files)
    # --------------------------------------------------------------------------
    # 逻辑: B 矩阵需要按 (K, N) 双重切分。
    # 每一个文件代表一个 12x16 的物理 Tile。
    for n in range(num_n_tiles):
        for k in range(num_k_tiles):
            filename = f"{OUT_DIR}/weight_k{k}_n{n}.mem"
            
            row_start = k * ARRAY_ROW
            row_end   = row_start + ARRAY_ROW
            col_start = n * ARRAY_COL
            col_end   = col_start + ARRAY_COL
            
            sub_b = mat_b[row_start:row_end, col_start:col_end] # Shape: [12, 16]

            with open(filename, "w") as f:
                for r in range(ARRAY_ROW): # 遍历 12 行
                    # 拼接 16 个数，每个 8bit。Col 15 在高位。
                    line_hex = ""
                    for c in range(ARRAY_COL - 1, -1, -1):
                        line_hex += to_hex(sub_b[r, c], 8)
                    f.write(line_hex + "\n")
            print(f"    -> 生成权重: {filename}")

    # --------------------------------------------------------------------------
    # 6. 生成结果矩阵 C 的切片文件 (Golden Files)
    # --------------------------------------------------------------------------
    # 逻辑: C 矩阵按 N 维度切分。每个文件包含 16 列的完整 32 行结果。
    for n in range(num_n_tiles):
        filename = f"{OUT_DIR}/golden_n{n}.mem"
        
        col_start = n * ARRAY_COL
        col_end   = col_start + ARRAY_COL
        sub_c = mat_c_golden[:, col_start:col_end] # Shape: [32, 16]

        with open(filename, "w") as f:
            for t in range(M_DIM):
                line_hex = ""
                for c in range(ARRAY_COL - 1, -1, -1):
                    line_hex += to_hex(sub_c[t, c], 32)
                f.write(line_hex + "\n")
        print(f"    -> 生成答案: {filename}")

if __name__ == "__main__":
    generate_core_vectors()