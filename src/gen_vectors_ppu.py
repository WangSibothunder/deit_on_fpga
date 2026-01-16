import numpy as np
import os

# --- Configuration ---
NUM_TESTS = 100
ARRAY_COL = 16
DATA_WIDTH_IN = 32
DATA_WIDTH_OUT = 8

OUT_DIR = "src/test_data"
if not os.path.exists(OUT_DIR):
    os.makedirs(OUT_DIR)

# --- PPU Configuration ---
CFG_MULT  = 256       # Scale = 1.0
CFG_SHIFT = 8
CFG_ZP    = 10
CFG_BIAS  = 50        # NEW: Test Bias

def to_hex(val, width):
    val = int(val)
    if val < 0:
        val = (1 << width) + val
    return f"{val:0{width//4}x}"

def simulate_ppu_op(val_in, mult, shift, zp, bias):
    """
    Logic: Clamp( ((In + Bias) * Mult >> Shift) + ZP )
    """
    # 0. Add Bias
    val_biased = val_in + bias

    # 1. Multiply
    product = val_biased * mult
    
    # 2. Shift
    shifted = product >> shift
    
    # 3. Add ZP
    with_zp = shifted + zp
    
    # 4. Clamp
    if with_zp > 127: return 127
    elif with_zp < -128: return -128
    else: return with_zp

def generate_ppu_vectors():
    print(f"Generating PPU Vectors with Bias...")
    print(f"Config: Mult={CFG_MULT}, Shift={CFG_SHIFT}, ZP={CFG_ZP}, Bias={CFG_BIAS}")

    inputs = np.random.randint(-200, 200, size=(NUM_TESTS, ARRAY_COL), dtype=np.int32)
    golden = np.zeros_like(inputs, dtype=np.int8)
    
    for r in range(NUM_TESTS):
        for c in range(ARRAY_COL):
            val = inputs[r, c]
            res = simulate_ppu_op(val, CFG_MULT, CFG_SHIFT, CFG_ZP, CFG_BIAS)
            golden[r, c] = res

    # Write Files
    with open(f"{OUT_DIR}/ppu_inputs.mem", "w") as f_in, \
         open(f"{OUT_DIR}/ppu_golden.mem", "w") as f_out:
        for r in range(NUM_TESTS):
            line_in = ""
            for c in range(ARRAY_COL-1, -1, -1):
                line_in += to_hex(inputs[r, c], 32)
            f_in.write(line_in + "\n")
            
            line_out = ""
            for c in range(ARRAY_COL-1, -1, -1):
                line_out += to_hex(golden[r, c], 8)
            f_out.write(line_out + "\n")

    # Write Config (Added Bias at line 3)
    with open(f"{OUT_DIR}/ppu_config.mem", "w") as f_cfg:
        f_cfg.write(f"{to_hex(CFG_MULT, 16)}\n")
        f_cfg.write(f"{to_hex(CFG_SHIFT, 8)}\n")
        f_cfg.write(f"{to_hex(CFG_ZP, 8)}\n")
        f_cfg.write(f"{to_hex(CFG_BIAS, 32)}\n") # NEW Line

    print(f"Generated data in {OUT_DIR}")

if __name__ == "__main__":
    generate_ppu_vectors()