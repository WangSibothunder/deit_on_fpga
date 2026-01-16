#!/bin/bash
# Description: PPU Verification Script with Python Generation

# 1. Configuration
MODULE_NAME="ppu"
TB_MODULE="${MODULE_NAME}_tb"
SIM_OUT="src/${MODULE_NAME}_sim.out"
VCD_FILE="ppu_verify.vcd"

# 2. Generate Data
echo "[1/3] Generating Test Vectors (Python)..."
python src/gen_vectors_ppu.py

if [ $? -ne 0 ]; then
    echo "❌ Python script failed."
    exit 1
fi

# 3. Compile
echo "[2/3] Compiling RTL..."
iverilog -g2005-sv -I src -o ${SIM_OUT} \
    src/params.vh \
    src/${MODULE_NAME}.v \
    src/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation FAILED."
    exit 1
fi

# 4. Simulate
echo "[3/3] Running Simulation..."
vvp ${SIM_OUT}
gtkwave ${VCD_FILE} &
if [ $? -ne 0 ]; then
    echo "❌ Simulation Runtime FAILED."
    exit 1
fi

# Cleanup (Optional)
# rm ${SIM_OUT}