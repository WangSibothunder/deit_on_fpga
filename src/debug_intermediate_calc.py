import numpy as np

# ==============================================================================
# 配置区域
# ==============================================================================
M = 32   # Sequence Length
K = 12   # Hardware K dimension (Tile size)
N = 16   # Output Dimension

# 文件路径 (请根据你的实际文件名修改)
FILE_IN_K0 = "src/test_data_top/axis_input_k0.mem"
FILE_IN_K1 = "src/test_data_top/axis_input_k1.mem"

FILE_W_K0  = "src/test_data_top/axis_weight_k0_n0.mem"
FILE_W_K1  = "src/test_data_top/axis_weight_k1_n0.mem" # 注意：这里假设是计算 N0 Tile

# ==============================================================================
# 辅助函数：加载 Hex 文件并解析
# ==============================================================================
def load_mem_64bit(filename, rows, cols_per_row):
    """
    读取 64-bit 宽度的 .mem 文件并解析为 INT8 矩阵
    Input Buffer: 64-bit 包含 8 个 INT8。
    """
    data_list = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
            for line in lines:
                line = line.strip()
                if not line or line.startswith("//"): continue
                # 64-bit hex -> 8 bytes
                val = int(line, 16)
                for i in range(8):
                    # Extract byte (Little Endian in terms of vector packing usually)
                    # input_buffer_ctrl logic: {s_axis_tdata[63:56] ... s_axis_tdata[7:0]}
                    # 通常 Python 处理时，低位在 list 前面比较方便调试，视具体 Gearbox 而定
                    # 这里假设 hex string "0102..." -> 01 是高位。
                    # 让我们按 Big Endian byte order 解析 hex 字符串流
                    byte_val = (val >> (i * 8)) & 0xFF
                    # Convert to signed int8
                    if byte_val > 127: byte_val -= 256
                    data_list.append(byte_val)
    except FileNotFoundError:
        print(f"Error: File {filename} not found.")
        return np.zeros((rows, cols_per_row), dtype=np.int8)

    # Convert to numpy array
    # Input files are usually packed streams. 
    # M=32, K=12. Total 384 elements.
    # Each line 8 elements. Lines needed = 384/8 = 48 lines.
    arr = np.array(data_list[:rows*cols_per_row], dtype=np.int8)
    return arr.reshape((rows, cols_per_row))

def load_weight_64bit(filename, rows, cols):
    """
    读取 Weight .mem 文件。
    K=12, N=16. Total 192 elements.
    """
    # Similar logic, just different shape
    data_list = []
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
            for line in lines:
                val = int(line.strip(), 16)
                for i in range(8):
                    byte_val = (val >> (i * 8)) & 0xFF
                    if byte_val > 127: byte_val -= 256
                    data_list.append(byte_val)
    except FileNotFoundError:
        print(f"Error: File {filename} not found.")
        return np.zeros((rows, cols), dtype=np.int8)
        
    arr = np.array(data_list[:rows*cols], dtype=np.int8)
    # Weights are usually stored [K, N] or [N, K]. 
    # Assuming Systolic Array standard: [K, N]
    return arr.reshape((rows, cols))

def save_debug_file(filename, matrix, note=""):
    """
    保存矩阵为易读的格式 (Decimal & Hex)
    """
    with open(filename, 'w') as f:
        f.write(f"// Debug Data: {note}\n")
        f.write(f"// Dimensions: {matrix.shape}\n")
        rows, cols = matrix.shape
        for r in range(rows):
            line_vals = []
            for c in range(cols):
                val = matrix[r, c]
                # Format: Dec(Hex)
                line_vals.append(f"{val:5d}") 
            f.write(" ".join(line_vals) + "\n")
    print(f"Saved {filename}")

# ==============================================================================
# 主逻辑
# ==============================================================================

print("=== Simulating Hardware Tiling Steps ===")

# 1. Load Data
# 注意：这里假设 .mem 文件里的数据排列顺序与硬件读取顺序一致
A_k0 = load_mem_64bit(FILE_IN_K0, M, K)
A_k1 = load_mem_64bit(FILE_IN_K1, M, K)

W_k0 = load_weight_64bit(FILE_W_K0, K, N)
W_k1 = load_weight_64bit(FILE_W_K1, K, N)

# 2. Step 1: Calculate Partial Sum (K=0)
# Corresponds to hardware behavior after first K-loop
Acc_step1 = np.dot(A_k0, W_k0).astype(np.int32)
save_debug_file("debug_k0_partial.txt", Acc_step1, "Step 1: A_k0 * W_k0 (Accumulator Value)")

# 3. Step 2: Accumulate (K=1)
# Corresponds to hardware behavior after second K-loop
Acc_step2 = Acc_step1 + np.dot(A_k1, W_k1).astype(np.int32)
save_debug_file("debug_k1_final.txt", Acc_step2, "Step 2: Acc + A_k1 * W_k1 (Final Accumulator Value)")

# 4. PPU Simulation (Optional Check)
# Simple scale for verification
scale = 0.001 # Dummy scale
bias = 0
PPU_out = np.clip((Acc_step2 * scale) + bias, -128, 127).astype(np.int8)
# We don't save PPU out here, focus on Accumulator first.

print("\n=== Diagnosis Guide ===")
print("请在波形图中观察 'u_core.u_accum.ram' 的内容，或者 'out_acc_vec' 信号。")
print("1. 当第一次计算结束 (Step K=0) 时，Accumulator 的值应该等于 debug_k0_partial.txt")
print("2. 当第二次计算结束 (Step K=1) 时，Accumulator 的值应该等于 debug_k1_final.txt")
print("3. 特别注意第 0 行和第 1 行的值，检查是否存在错位。")