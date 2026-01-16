import numpy as np
import os

# --- Configuration ---
NUM_TESTS = 100       # Generate 100 random vectors
ARRAY_COL = 16        # 16 Parallel Lanes
DATA_WIDTH_IN = 32    # Input INT32
DATA_WIDTH_OUT = 8    # Output INT8

OUT_DIR = "src/test_data"
if not os.path.exists(OUT_DIR):
    os.makedirs(OUT_DIR)

# --- PPU Configuration (Static for this batch) ---
# You can change these to test different scaling factors
CFG_MULT  = 256       # Example: 1.0 scaling if shift is 8 (256/2^8 = 1)
CFG_SHIFT = 8         # Right shift by 8
CFG_ZP    = 10        # Zero Point offset (Unsigned 0-255)

def to_hex(val, width):
    """Convert integer to hex string with fixed width handling 2's complement"""
    val = int(val)
    if val < 0:
        val = (1 << width) + val
    return f"{val:0{width//4}x}"

def simulate_ppu_op(val_in, mult, shift, zp):
    """
    Simulate the Verilog logic:
    1. Product = Input * Mult
    2. Shifted = Product >>> Shift (Arithmetic Right Shift)
    3. WithZP  = Shifted + ZP (Zero Extended)
    4. Clamped = Clip to [-128, 127]
    """
    # 1. Multiply
    product = val_in * mult
    
    # 2. Shift (Python >> is arithmetic for negative numbers)
    shifted = product >> shift
    
    # 3. Add ZP (Verilog implementation treats ZP as unsigned extension)
    with_zp = shifted + zp
    
    # 4. Clamp to INT8 signed range
    if with_zp > 127:
        return 127
    elif with_zp < -128:
        return -128
    else:
        return with_zp

def generate_ppu_vectors():
    print(f"Generating {NUM_TESTS} vectors for PPU Verification...")
    print(f"Config: Mult={CFG_MULT}, Shift={CFG_SHIFT}, ZP={CFG_ZP}")

    # 1. Generate Random Inputs (INT32)
    # Range: Choose a range that triggers clamping and normal behavior
    # Some small numbers, some large numbers
    inputs = np.random.randint(-500, 500, size=(NUM_TESTS, ARRAY_COL), dtype=np.int32)

    # 2. Calculate Golden Outputs
    golden = np.zeros_like(inputs, dtype=np.int8)
    
    for r in range(NUM_TESTS):
        for c in range(ARRAY_COL):
            val = inputs[r, c]
            res = simulate_ppu_op(val, CFG_MULT, CFG_SHIFT, CFG_ZP)
            golden[r, c] = res

    # 3. Write to Hex Files
    # ppu_inputs.mem: 16 * 32-bit = 512 bits per line
    # ppu_golden.mem: 16 * 8-bit  = 128 bits per line
    # Order: Lane 15 (MSB) -> Lane 0 (LSB)

    with open(f"{OUT_DIR}/ppu_inputs.mem", "w") as f_in, \
         open(f"{OUT_DIR}/ppu_golden.mem", "w") as f_out:
        
        for r in range(NUM_TESTS):
            # Build Input Line
            line_in = ""
            for c in range(ARRAY_COL-1, -1, -1):
                line_in += to_hex(inputs[r, c], 32)
            f_in.write(line_in + "\n")
            
            # Build Output Line
            line_out = ""
            for c in range(ARRAY_COL-1, -1, -1):
                line_out += to_hex(golden[r, c], 8)
            f_out.write(line_out + "\n")

    # Write Config File for TB to read
    with open(f"{OUT_DIR}/ppu_config.mem", "w") as f_cfg:
        # Mult, Shift, ZP
        f_cfg.write(f"{to_hex(CFG_MULT, 16)}\n")
        f_cfg.write(f"{to_hex(CFG_SHIFT, 8)}\n") # Using 8 bit container for 5 bit
        f_cfg.write(f"{to_hex(CFG_ZP, 8)}\n")

    print(f"Generated data in {OUT_DIR}")

if __name__ == "__main__":
    generate_ppu_vectors()