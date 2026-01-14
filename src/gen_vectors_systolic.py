import numpy as np
import os

# --- 配置参数 ---
SEQ_LEN = 32      # 输入序列长度
ARRAY_ROW = 12    # 物理阵列行数 (Inputs/Activations)
ARRAY_COL = 16    # 物理阵列列数 (Weights/Partial Sums)

OUTPUT_DIR = "src/test_data"

def to_hex(value, width):
    """
    将整数转换为指定位宽的十六进制字符串，处理补码。
    关键修复: 强制将 numpy 类型转换为 python int，防止 OverflowError
    """
    value = int(value) # <--- FIX: 强制转换，脱离 numpy 类型限制
    if value < 0:
        value = (1 << width) + value
    # 格式化为 hex，宽度不足补0
    return f"{value:0{width // 4}x}"

def generate_files():
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
        print(f"Created directory: {OUTPUT_DIR}")

    print(f"Generating random data for Systolic Array ({ARRAY_ROW}x{ARRAY_COL})...")

    # 1. 生成权重 Weights (Rows=12, Cols=16)
    # 范围 [-127, 127]
    weights = np.random.randint(-100, 100, size=(ARRAY_ROW, ARRAY_COL), dtype=np.int8)
    
    # 2. 生成输入 Inputs (Sequence=32, Rows=12)
    # 模拟流式输入
    inputs = np.random.randint(-100, 100, size=(SEQ_LEN, ARRAY_ROW), dtype=np.int8)

    # 3. 计算 Golden Output
    # 矩阵乘法: (32, 12) x (12, 16) = (32, 16)
    # 结果累加到 32-bit，不会溢出
    golden_output = np.matmul(inputs.astype(np.int32), weights.astype(np.int32))

    # --- 写入文件 (注意: Hex 字符串最右侧对应 Verilog 的 [7:0] / Index 0) ---

    # 1. weights.mem
    # 每一行包含该 Row 加载进来的 16 个 Column 的权重
    # 位宽: ARRAY_COL * 8 = 128 bits
    # 顺序: Col 15 (High) -> Col 0 (Low)
    with open(f"{OUTPUT_DIR}/sa_weights.mem", "w") as f:
        for r in range(ARRAY_ROW):
            hex_str = ""
            for c in range(ARRAY_COL - 1, -1, -1): # 逆序: 15...0
                hex_str += to_hex(weights[r, c], 8)
            f.write(f"{hex_str}\n")
    print(f"Generated {OUTPUT_DIR}/sa_weights.mem")

    # 2. inputs.mem
    # 每一行包含 T 时刻喂给 12 行的 Input
    # 位宽: ARRAY_ROW * 8 = 96 bits
    # 顺序: Row 11 (High) -> Row 0 (Low)
    with open(f"{OUTPUT_DIR}/sa_inputs.mem", "w") as f:
        for t in range(SEQ_LEN):
            hex_str = ""
            for r in range(ARRAY_ROW - 1, -1, -1): # 逆序: 11...0
                hex_str += to_hex(inputs[t, r], 8)
            f.write(f"{hex_str}\n")
    print(f"Generated {OUTPUT_DIR}/sa_inputs.mem")

    # 3. golden.mem
    # 每一行包含 T 时刻流出的 16 个 Column 的结果
    # 位宽: ARRAY_COL * 32 = 512 bits
    # 顺序: Col 15 (High) -> Col 0 (Low)
    with open(f"{OUTPUT_DIR}/sa_golden.mem", "w") as f:
        for t in range(SEQ_LEN):
            hex_str = ""
            for c in range(ARRAY_COL - 1, -1, -1): # 逆序: 15...0
                hex_str += to_hex(golden_output[t, c], 32)
            f.write(f"{hex_str}\n")
    print(f"Generated {OUTPUT_DIR}/sa_golden.mem")

    print("Data generation complete.")

if __name__ == "__main__":
    generate_files()