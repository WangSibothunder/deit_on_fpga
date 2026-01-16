import numpy as np
import os

def generate_test_data():
    os.makedirs('src/test_data_core', exist_ok=True)
    
    # --- Matrix Dimensions ---
    M = 36   # Sequence Length
    K = 24   # Input Depth
    N = 16   # Output Width
    
    # --- Tiling Parameters ---
    # Hardware Array Height = 12
    # We split K into 2 chunks of 12.
    # We split M into 2 chunks of 18 (Arbitrary split to test multi-batch).
    M_SPLIT = 18
    K_SPLIT = 12
    
    print(f"Generating Blocked GEMM Data:")
    print(f"  Input A [{M}x{K}] -> Split into 4 Blocks (2x2)")
    print(f"  Weight W [{K}x{N}] -> Split into 2 Blocks (2x1)")
    print(f"  Output Y [{M}x{N}]")

    # 1. Random Generation
    inputs_full  = np.random.randint(-8, 8, size=(M, K)).astype(np.int8)
    weights_full = np.random.randint(-8, 8, size=(K, N)).astype(np.int8)
    
    # 2. Golden Calculation
    golden_full = np.dot(inputs_full, weights_full).astype(np.int32)
    
    # 3. Slicing & Saving (The "Four Matrices" Strategy)
    
    # --- Weights (Split by K) ---
    # W0: Rows 0-11
    # W1: Rows 12-23
    w_k0 = weights_full[0:K_SPLIT, :]
    w_k1 = weights_full[K_SPLIT:, :]
    
    # --- Inputs (Split by M and K) ---
    # A00: M(0-17), K(0-11)
    a_m0_k0 = inputs_full[0:M_SPLIT, 0:K_SPLIT]
    # A01: M(0-17), K(12-23)
    a_m0_k1 = inputs_full[0:M_SPLIT, K_SPLIT:]
    
    # A10: M(18-35), K(0-11)
    a_m1_k0 = inputs_full[M_SPLIT:, 0:K_SPLIT]
    # A11: M(18-35), K(12-23)
    a_m1_k1 = inputs_full[M_SPLIT:, K_SPLIT:]
    
    # Helper: Write Weights (128-bit hex per row)
    def write_weights(filename, w_mat):
        with open(filename, 'w') as f:
            for r in range(w_mat.shape[0]):
                row_data = w_mat[r, :] # 16 bytes
                hex_val = "".join([f"{x & 0xff:02X}" for x in reversed(row_data)])
                f.write(f"{hex_val}\n")

    # Helper: Write Inputs (96-bit hex per row, padded from 12 bytes)
    def write_inputs(filename, i_mat):
        with open(filename, 'w') as f:
            for m in range(i_mat.shape[0]):
                row_data = i_mat[m, :] # 12 bytes
                hex_val = "".join([f"{x & 0xff:02X}" for x in reversed(row_data)])
                f.write(f"{hex_val}\n")
                
    # Helper: Write Golden (Flat 32-bit words)
    def write_golden(filename, g_mat):
        with open(filename, 'w') as f:
            for m in range(g_mat.shape[0]):
                for n in range(g_mat.shape[1]):
                    val = g_mat[m, n]
                    f.write(f"{val & 0xffffffff:08X}\n")

    # Save Files
    write_weights('src/test_data_core/w_k0.mem', w_k0)
    write_weights('src/test_data_core/w_k1.mem', w_k1)
    
    write_inputs ('src/test_data_core/a_m0_k0.mem', a_m0_k0)
    write_inputs ('src/test_data_core/a_m0_k1.mem', a_m0_k1)
    write_inputs ('src/test_data_core/a_m1_k0.mem', a_m1_k0)
    write_inputs ('src/test_data_core/a_m1_k1.mem', a_m1_k1)
    
    write_golden ('src/test_data_core/golden.mem', golden_full)
    
    print(f"Generated 7 files in src/test_data_core/")

if __name__ == "__main__":
    generate_test_data()