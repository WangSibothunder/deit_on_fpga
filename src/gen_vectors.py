import numpy as np
import os

# --- Configuration ---
# Hardware Constraints
ARRAY_ROW = 12  # Physical Rows (K dimension per tile)
ARRAY_COL = 16  # Physical Cols (N dimension per tile)
DATA_WIDTH = 8
ACC_WIDTH = 32

# Test Matrix Dimensions
M = 16  # Sequence Length (Time steps)
K = 24  # Input Features (Must be split into 2 tiles of 12)
N = 16  # Output Features

# Paths
OUT_DIR = "/Users/wangsibo/program/deit_on_fpga/src/test_data"
if not os.path.exists(OUT_DIR):
    os.makedirs(OUT_DIR)

def to_hex(arr, width):
    """Convert numpy array to hex string for Verilog readmemh"""
    # flatten handling depends on the shape, but here we process row by row/vector
    hex_lines = []
    # Handle negative numbers for INT8/INT32
    mask = (1 << width) - 1
    for val in arr:
        val = int(val) & mask
        # Format to hex with correct zero padding
        hex_lines.append(f"{val:0{width//4}x}")
    return "".join(reversed(hex_lines)) # Little Endian for Verilog vector construction

def generate_test_data():
    print(f"Generating Matrix Verification Data...")
    print(f"Shape: A({M}x{K}) * B({K}x{N}) = C({M}x{N})")
    
    # 1. Generate Random Data (INT8)
    # Range -64 to 64 to avoid overflow too quickly, though ACC is 32-bit (safe)
    np.random.seed(42)
    A = np.random.randint(-10, 10, size=(M, K), dtype=np.int8)
    B = np.random.randint(-10, 10, size=(K, N), dtype=np.int8)
    
    # 2. Compute Golden Result
    # Need to verify accumulator logic, so use int32
    C_golden = np.matmul(A.astype(np.int32), B.astype(np.int32))
    
    # 3. Split into Tiles for Hardware
    # We split K dimension into 2 tiles of size ARRAY_ROW (12)
    # Tile 1: K = [0:12]
    # Tile 2: K = [12:24]
    
    K_TILE_SIZE = ARRAY_ROW
    
    # --- Tile 1 Data ---
    A_t1 = A[:, 0:K_TILE_SIZE]      # (16, 12)
    B_t1 = B[0:K_TILE_SIZE, :]      # (12, 16)
    
    # --- Tile 2 Data ---
    A_t2 = A[:, K_TILE_SIZE:2*K_TILE_SIZE] # (16, 12)
    B_t2 = B[K_TILE_SIZE:2*K_TILE_SIZE, :] # (12, 16)
    
    # 4. Export to Hex Files
    
    # Function to write weight file (Rows of B are loaded 1 by 1)
    # Hardware expects: vector of ARRAY_COL bytes.
    # We write 12 lines (one per physical row load).
    def write_weight_file(filename, matrix_b):
        with open(filename, 'w') as f:
            # Matrix B is (12, 16). 
            # Row 0 of B is loaded into Row 0 of Array.
            for r in range(matrix_b.shape[0]):
                # Each row has 16 elements (Cols)
                row_data = matrix_b[r, :]
                f.write(to_hex(row_data, DATA_WIDTH) + "\n")
    
    # Function to write input activation file (fed cycle by cycle)
    # Hardware expects: vector of ARRAY_ROW bytes.
    # We write 16 lines (one per time step M).
    def write_input_file(filename, matrix_a):
        with open(filename, 'w') as f:
            # Matrix A is (16, 12).
            # Each time step (row of A), we feed 12 elements (K dim)
            for m in range(matrix_a.shape[0]):
                row_data = matrix_a[m, :]
                f.write(to_hex(row_data, DATA_WIDTH) + "\n")

    # Function to write golden output
    def write_golden_file(filename, matrix_c):
        with open(filename, 'w') as f:
            # Matrix C is (16, 16)
            for m in range(matrix_c.shape[0]):
                row_data = matrix_c[m, :]
                f.write(to_hex(row_data, ACC_WIDTH) + "\n")

    # Write Files
    write_weight_file(os.path.join(OUT_DIR, "weights_t1.mem"), B_t1)
    write_input_file(os.path.join(OUT_DIR, "inputs_t1.mem"), A_t1)
    
    write_weight_file(os.path.join(OUT_DIR, "weights_t2.mem"), B_t2)
    write_input_file(os.path.join(OUT_DIR, "inputs_t2.mem"), A_t2)
    
    write_golden_file(os.path.join(OUT_DIR, "golden_c.mem"), C_golden)
    
    print(f"Data generated in {OUT_DIR}")
    print("Example Golden Row 0:", C_golden[0])

if __name__ == "__main__":
    generate_test_data()