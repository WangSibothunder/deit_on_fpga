import argparse
import numpy as np
import os

# ==============================================================================
# Dual-case vector generator for top-level verification
# ==============================================================================
ARRAY_ROW = 12
ARRAY_COL = 16

# --- PPU params (software model) ---
# Out = Clamp( ((In + Bias) * Mult >> Shift) + ZP )
CFG_BIAS  = 100
CFG_MULT  = 180   # 0.703 (180/256)
CFG_SHIFT = 8
CFG_ZP    = 10

OUT_ROOT = "src/test_data_top"


def to_hex(val, width):
    val = int(val)
    if val < 0:
        val = (1 << width) + val
    return f"{val:0{width//4}x}"


def ppu_software_model(val_in):
    val_biased = val_in + CFG_BIAS
    val_mult = val_biased * CFG_MULT
    val_shifted = val_mult >> CFG_SHIFT
    val_zp = val_shifted + CFG_ZP
    if val_zp > 127:
        return 127
    if val_zp < -128:
        return -128
    return val_zp


def ceil_to(x, base):
    return ((x + base - 1) // base) * base


def generate_case(case_id, m_dim, k_dim, n_dim, seed, out_dir):
    print(f"=== Case{case_id}: Generating Top-Level Vectors ===")
    print(f"Matrix: [{m_dim}x{k_dim}] * [{k_dim}x{n_dim}] -> PPU -> INT8")

    # Pad sizes
    m_pad = m_dim if (m_dim % 2 == 0) else (m_dim + 1)
    k_pad = ceil_to(k_dim, ARRAY_ROW)
    n_pad = ceil_to(n_dim, ARRAY_COL)

    k_tiles = k_pad // ARRAY_ROW
    n_tiles = n_pad // ARRAY_COL

    print(f"Pad: M={m_pad} K={k_pad} N={n_pad}")
    print(f"Tiles: K={k_tiles} N={n_tiles}")

    # Generate source data
    if seed is not None:
        np.random.seed(seed)
    mat_a = np.random.randint(-10, 10, size=(m_dim, k_dim), dtype=np.int8)
    mat_b = np.random.randint(-10, 10, size=(k_dim, n_dim), dtype=np.int8)

    # Pad A/B
    a_pad = np.zeros((m_pad, k_pad), dtype=np.int8)
    b_pad = np.zeros((k_pad, n_pad), dtype=np.int8)
    a_pad[:m_dim, :k_dim] = mat_a
    b_pad[:k_dim, :n_dim] = mat_b

    # Golden INT32
    c_pad_int32 = np.matmul(a_pad.astype(np.int32), b_pad.astype(np.int32))

    # Golden INT8 after PPU
    c_pad_int8 = np.zeros_like(c_pad_int32, dtype=np.int8)
    for r in range(m_pad):
        for c in range(n_pad):
            c_pad_int8[r, c] = ppu_software_model(c_pad_int32[r, c])

    os.makedirs(out_dir, exist_ok=True)

    # --------------------------------------------------------------------------
    # A: AXI Input Stream (single file)
    # --------------------------------------------------------------------------
    input_path = f"{out_dir}/axis_input.mem"
    with open(input_path, "w") as f:
        for k_idx in range(k_tiles):
            col_start = k_idx * ARRAY_ROW
            sub_matrix = a_pad[:, col_start:col_start + ARRAY_ROW]  # M_PAD x 12

            byte_list = []
            for t in range(m_pad):
                for r in range(ARRAY_ROW):
                    byte_list.append(sub_matrix[t, r])

            for i in range(0, len(byte_list), 8):
                chunk = byte_list[i:i + 8]
                line = ""
                for b in reversed(chunk):
                    line += to_hex(b, 8)
                f.write(line + "\n")
    print(f"[AXI-Stream] Input: {input_path}")

    # --------------------------------------------------------------------------
    # B: AXI Weight Stream (single file)
    # --------------------------------------------------------------------------
    weight_path = f"{out_dir}/axis_weight.mem"
    with open(weight_path, "w") as f:
        for n_idx in range(n_tiles):
            for k_idx in range(k_tiles):
                r_start = k_idx * ARRAY_ROW
                c_start = n_idx * ARRAY_COL
                sub_matrix = b_pad[r_start:r_start + ARRAY_ROW, c_start:c_start + ARRAY_COL]

                for r in range(ARRAY_ROW):
                    val_128 = 0
                    for c in range(ARRAY_COL):
                        val = int(sub_matrix[r, c])
                        if val < 0:
                            val = 256 + val
                        val_128 |= (val << (c * 8))
                    low_64 = val_128 & 0xFFFFFFFFFFFFFFFF
                    high_64 = (val_128 >> 64) & 0xFFFFFFFFFFFFFFFF
                    f.write(to_hex(low_64, 64) + "\n")
                    f.write(to_hex(high_64, 64) + "\n")
    print(f"[AXI-Stream] Weight: {weight_path}")

    # --------------------------------------------------------------------------
    # C: AXI Golden Output (single file)
    # --------------------------------------------------------------------------
    golden_path = f"{out_dir}/axis_golden.mem"
    with open(golden_path, "w") as f:
        for n_idx in range(n_tiles):
            c_start = n_idx * ARRAY_COL
            sub_matrix = c_pad_int8[:, c_start:c_start + ARRAY_COL]  # M_PAD x 16

            for t in range(m_pad):
                val_128 = 0
                for c in range(ARRAY_COL):
                    val = int(sub_matrix[t, c])
                    if val < 0:
                        val = 256 + val
                    val_128 |= (val << (c * 8))
                low_64 = val_128 & 0xFFFFFFFFFFFFFFFF
                high_64 = (val_128 >> 64) & 0xFFFFFFFFFFFFFFFF
                f.write(to_hex(low_64, 64) + "\n")
                f.write(to_hex(high_64, 64) + "\n")
    print(f"[AXI-Stream] Golden: {golden_path}")

    # --------------------------------------------------------------------------
    # D: RAM Golden for CKPT-B (col0 & col1 only)
    # --------------------------------------------------------------------------
    ram_golden_path = f"{out_dir}/ram_golden_c01.mem"
    with open(ram_golden_path, "w") as f:
        for n_idx in range(n_tiles):
            acc = np.zeros((m_pad, ARRAY_COL), dtype=np.int32)
            for k_idx in range(k_tiles):
                r_start = k_idx * ARRAY_ROW
                c_start = n_idx * ARRAY_COL
                a_sub = a_pad[:, r_start:r_start + ARRAY_ROW]
                b_sub = b_pad[r_start:r_start + ARRAY_ROW, c_start:c_start + ARRAY_COL]
                acc += np.matmul(a_sub.astype(np.int32), b_sub.astype(np.int32))

                for t in range(m_pad):
                    col0 = int(acc[t, 0]) & 0xFFFFFFFF
                    col1 = int(acc[t, 1]) & 0xFFFFFFFF
                    line = (col1 << 32) | col0
                    f.write(to_hex(line, 64) + "\n")
    print(f"[CKPT-B] RAM Golden (col0/1): {ram_golden_path}")

    # --------------------------------------------------------------------------
    # E: Config
    # --------------------------------------------------------------------------
    with open(f"{out_dir}/config.mem", "w") as f:
        f.write(to_hex(CFG_MULT, 32) + "\n")
        f.write(to_hex(CFG_SHIFT, 32) + "\n")
        f.write(to_hex(CFG_ZP, 32) + "\n")
        f.write(to_hex(CFG_BIAS, 32) + "\n")
        f.write(to_hex(m_dim, 32) + "\n")
        f.write(to_hex(k_dim, 32) + "\n")
        f.write(to_hex(n_dim, 32) + "\n")
        f.write(to_hex(m_pad, 32) + "\n")
        f.write(to_hex(k_pad, 32) + "\n")
        f.write(to_hex(n_pad, 32) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Generate dual-case top-level test vectors")
    parser.add_argument("--seed1", type=int, default=1, help="Random seed for case1")
    parser.add_argument("--seed2", type=int, default=2, help="Random seed for case2")
    args = parser.parse_args()

    os.makedirs(OUT_ROOT, exist_ok=True)

    # Case 1: 48x36 * 36x48
    generate_case(1, 48, 36, 48, args.seed1, f"{OUT_ROOT}/case1")

    # Case 2: 67x93 * 93x67
    generate_case(2, 67, 93, 67, args.seed2, f"{OUT_ROOT}/case2")


if __name__ == "__main__":
    main()
