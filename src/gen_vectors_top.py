import numpy as np
import os

# ==============================================================================
# 1. 系统配置
# ==============================================================================
M_DIM = 32   # 序列长度
K_DIM = 24   # 输入通道
N_DIM = 32   # 输出通道

ARRAY_ROW = 12
ARRAY_COL = 16

# --- PPU 量化参数 (模拟真实模型) ---
# 假设我们想把较大的 INT32 缩放到 INT8
# Formula: Out = Clamp( ((In + Bias) * Mult >> Shift) + ZP )
CFG_BIAS  = 100
CFG_MULT  = 180   # 0.703 (180/256)
CFG_SHIFT = 8
CFG_ZP    = 10

OUT_DIR = "src/test_data_top"
if not os.path.exists(OUT_DIR):
    os.makedirs(OUT_DIR)

# ==============================================================================
# 2. 辅助函数
# ==============================================================================
def to_hex(val, width):
    val = int(val)
    if val < 0: val = (1 << width) + val
    return f"{val:0{width//4}x}"

def ppu_software_model(val_in):
    """软件模拟硬件 PPU 行为 (Bit-exact)"""
    # 1. Add Bias
    val_biased = val_in + CFG_BIAS
    # 2. Multiply
    val_mult = val_biased * CFG_MULT
    # 3. Shift (Arithmetic Right Shift)
    val_shifted = val_mult >> CFG_SHIFT
    # 4. Add ZP
    val_zp = val_shifted + CFG_ZP
    # 5. Clamp to INT8
    if val_zp > 127: return 127
    elif val_zp < -128: return -128
    else: return val_zp

# ==============================================================================
# 3. 主生成流程
# ==============================================================================
def generate_system_vectors():
    print(f"=== 生成 Top-Level 测试向量 ===")
    print(f"矩阵: [{M_DIM}x{K_DIM}] * [{K_DIM}x{N_DIM}] -> PPU -> INT8")

    # 1. 生成源数据
    mat_a = np.random.randint(-10, 10, size=(M_DIM, K_DIM), dtype=np.int8)
    mat_b = np.random.randint(-10, 10, size=(K_DIM, N_DIM), dtype=np.int8)
    
    # 2. 计算理想结果 (INT32)
    mat_c_int32 = np.matmul(mat_a.astype(np.int32), mat_b.astype(np.int32))

    # 初始化累加器状态矩阵
    accumulator_state = np.zeros_like(mat_c_int32, dtype=np.int32)

    # 3. 计算 PPU 后结果 (INT8) - Golden Output
    mat_c_int8 = np.zeros_like(mat_c_int32, dtype=np.int8)
    for r in range(M_DIM):
        for c in range(N_DIM):
            mat_c_int8[r, c] = ppu_software_model(mat_c_int32[r, c])

    # 4. 生成数据流文件 (Tiling)
    num_k_tiles = K_DIM // ARRAY_ROW # 2
    num_n_tiles = N_DIM // ARRAY_COL # 2

    # --- 保存分块中间乘法结果 ---
    # 计算并保存4个mat_a子矩阵和4个mat_b子矩阵的分块中间乘法结果
    print("  保存分块中间乘法结果...")
    for k_idx in range(num_k_tiles):
        for n_idx in range(num_n_tiles):
            # 提取对应的子矩阵
            a_sub = mat_a[:, k_idx * ARRAY_ROW : (k_idx + 1) * ARRAY_ROW]  # M x ARRAY_ROW (32 x 12)
            b_sub = mat_b[k_idx * ARRAY_ROW : (k_idx + 1) * ARRAY_ROW, n_idx * ARRAY_COL : (n_idx + 1) * ARRAY_COL]  # ARRAY_ROW x ARRAY_COL (12 x 16)
            
            # 保存 mat_a 子矩阵 (参考 systolic_array 格式)
            # 每一行包含该时刻喂给12行的Input，位宽: ARRAY_ROW * 8 = 96 bits
            filename_a = f"{OUT_DIR}/input_k{k_idx}_n{n_idx}.mem"
            with open(filename_a, "w") as f:
                for t in range(M_DIM):  # 遍历M维度的所有行
                    hex_str = ""
                    for r in range(ARRAY_ROW - 1, -1, -1):  # 逆序: 11...0
                        hex_str += to_hex(a_sub[t, r], 8)
                    f.write(f"{hex_str}\n")
            
            # 保存 mat_b 子矩阵 (参考 systolic_array 格式)
            # 每一行包含该Row加载进来的16个Column的权重，位宽: ARRAY_COL * 8 = 128 bits
            filename_b = f"{OUT_DIR}/weight_k{k_idx}_n{n_idx}.mem"
            with open(filename_b, "w") as f:
                for r in range(ARRAY_ROW):
                    hex_str = ""
                    for c in range(ARRAY_COL - 1, -1, -1):  # 逆序: 15...0
                        hex_str += to_hex(b_sub[r, c], 8)
                    f.write(f"{hex_str}\n")
            
            # 计算中间乘法结果 (INT32)
            intermediate_result = np.matmul(a_sub.astype(np.int32), b_sub.astype(np.int32))  # M x ARRAY_COL (32 x 16)
            
            # 保存中间乘法结果到文件 (参考 systolic_array 格式)
            # 每一行包含T时刻流出的16个Column的结果，位宽: ARRAY_COL * 32 = 512 bits
            inter_filename = f"{OUT_DIR}/acc_golden_k{k_idx}_n{n_idx}.mem"
            with open(inter_filename, "w") as f:
                for t in range(M_DIM):
                    hex_str = ""
                    for c in range(ARRAY_COL - 1, -1, -1):  # 逆序: 15...0
                        hex_str += to_hex(int(intermediate_result[t, c]), 32)
                    f.write(f"{hex_str}\n")
            print(f"  [ACC] 中间乘法结果文件: {inter_filename}")
            
            # --- CHECK 2: Accumulator Memory Content (Accumulated Sum) ---
            
            # 这是硬件写回 RAM 后的值 (历史值 + 当前值)
            
            # 更新模拟累加器状态
            c_start = n_idx * ARRAY_COL
            c_end   = (n_idx + 1) * ARRAY_COL
            
            # 累加到全局状态中
            # 获取当前子矩阵的起始行
            r_start = k_idx * ARRAY_ROW
            # 将中间结果累加到对应的区域
            accumulator_state[:, c_start:c_end] += intermediate_result
            
            # 保存累加后的值 (用于检查 RAM)
            final_acc_filename = f"{OUT_DIR}/ram_golden_k{k_idx}_n{n_idx}.mem"
            with open(final_acc_filename, "w") as f:
                for t in range(M_DIM):
                    hex_str = ""
                    for c in range(ARRAY_COL - 1, -1, -1):
                        # 从全局累加器中取值
                        val = accumulator_state[t, c_start + c]
                        hex_str += to_hex(int(val), 32)
                    f.write(f"{hex_str}\n")
            print(f"  [DEBUG] RAM Golden值 (K={k_idx}): {final_acc_filename}")

    # --- A: Input Stream Files (A 矩阵) ---
    # 硬件 Input Buffer 需要 64-bit 宽度的流。
    # 原始数据是 12 行 (96-bit)。
    # Gearbox (3-to-2) 会把 3 个 64-bit 转换成 2 个 96-bit。
    # 所以我们需要把 mat_a 的每一列 (M行 x 12数) 打包成 64-bit 流。
    # 这是一个反向 Gearbox 过程：
    # 2 cycles of 96-bit (12 bytes) = 24 bytes
    # needs 3 cycles of 64-bit (8 bytes) = 24 bytes
    
    for k_idx in range(num_k_tiles):
        filename = f"{OUT_DIR}/axis_input_k{k_idx}.mem"
        col_start = k_idx * ARRAY_ROW
        sub_matrix = mat_a[:, col_start : col_start+ARRAY_ROW] # M x 12
        
        # 将矩阵展平为字节流 (Row 0, Row 1 ... Row 11, Next Time Step...)
        # 注意: 硬件 Input Buffer 是一次存入 96-bit (Row 11..0)。
        # 我们的 Gearbox 逻辑假定数据流是大端还是小端？
        # 硬件: {s_axis_tdata[31:0], temp_reg} -> 拼成 96bit
        # 这意味着低位先发。
        
        # 为了简化，我们先把 M 个 96-bit 向量构建出来，再拆解成 64-bit
        huge_bitstring = ""
        for t in range(M_DIM):
            # 构建 96-bit 向量 (Hex string)
            vec_96 = ""
            for r in range(ARRAY_ROW - 1, -1, -1):
                vec_96 += to_hex(sub_matrix[t, r], 8)
            huge_bitstring = vec_96 + huge_bitstring # LSB at end (Time 0 at end of string logic, but for file write we want line 0 first)
            # wait, let's use list of bytes
        
        # Better approach: Byte array
        byte_list = []
        for t in range(M_DIM):
            for r in range(ARRAY_ROW): # Row 0 first (LSB)
                byte_list.append(sub_matrix[t, r])
                
        # 现在 byte_list 长度应该能被 8 整除 (因为 12 * 32 = 384 bytes, /8 = 48 lines)
        with open(filename, "w") as f:
            for i in range(0, len(byte_list), 8): # 每次取 8 字节 (64-bit)
                chunk = byte_list[i:i+8]
                line = ""
                for b in reversed(chunk): # MSB byte last
                    line += to_hex(b, 8)
                f.write(line + "\n")
        print(f"  [AXI-Stream] 输入文件: {filename}")

    # --- B: Weight Stream Files (B 矩阵) ---
    # 权重: 12 行 x 16 列 (128-bit). 
    # 硬件 Weight Buffer Gearbox (2-to-1): 2个 64-bit -> 1个 128-bit.
    for n_idx in range(num_n_tiles):
        for k_idx in range(num_k_tiles):
            filename = f"{OUT_DIR}/axis_weight_k{k_idx}_n{n_idx}.mem"
            r_start = k_idx * ARRAY_ROW
            c_start = n_idx * ARRAY_COL
            sub_matrix = mat_b[r_start : r_start+ARRAY_ROW, c_start : c_start+ARRAY_COL]
            
            with open(filename, "w") as f:
                for r in range(ARRAY_ROW):
                    # 每一行 128-bit，拆成 2 个 64-bit
                    # Gearbox 逻辑: 先发 Low 64, 再发 High 64
                    
                    # Construct 128-bit value
                    val_128 = 0
                    for c in range(ARRAY_COL):
                        val = int(sub_matrix[r, c])
                        if val < 0: val = 256 + val
                        val_128 |= (val << (c * 8))
                    
                    # Split
                    low_64 = val_128 & 0xFFFFFFFFFFFFFFFF
                    high_64 = (val_128 >> 64) & 0xFFFFFFFFFFFFFFFF
                    
                    f.write(to_hex(low_64, 64) + "\n")
                    f.write(to_hex(high_64, 64) + "\n")
            print(f"  [AXI-Stream] 权重文件: {filename}")

    # --- C: Golden Output Files (INT8) ---
    # 硬件输出: AXI-Stream 64-bit
    # 内部 PPU 输出: 128-bit (16 cols * 8 bit).
    # 硬件 Output Gearbox: 128-bit -> 2个 64-bit (Low first)
    for n_idx in range(num_n_tiles):
        filename = f"{OUT_DIR}/axis_golden_n{n_idx}.mem"
        c_start = n_idx * ARRAY_COL
        sub_matrix = mat_c_int8[:, c_start : c_start+ARRAY_COL] # M x 16
        
        with open(filename, "w") as f:
            for t in range(M_DIM):
                # Construct 128-bit
                val_128 = 0
                for c in range(ARRAY_COL):
                    val = int(sub_matrix[t, c])
                    if val < 0: val = 256 + val
                    val_128 |= (val << (c * 8))
                
                low_64 = val_128 & 0xFFFFFFFFFFFFFFFF
                high_64 = (val_128 >> 64) & 0xFFFFFFFFFFFFFFFF
                
                f.write(to_hex(low_64, 64) + "\n")
                f.write(to_hex(high_64, 64) + "\n")
        print(f"  [AXI-Stream] Golden结果: {filename}")

    # 生成 Config 文件供 TB 读取
    with open(f"{OUT_DIR}/config.mem", "w") as f:
        f.write(to_hex(CFG_MULT, 32) + "\n")
        f.write(to_hex(CFG_SHIFT, 32) + "\n")
        f.write(to_hex(CFG_ZP, 32) + "\n")
        f.write(to_hex(CFG_BIAS, 32) + "\n")

if __name__ == "__main__":
    generate_system_vectors()