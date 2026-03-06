#!/bin/bash
# Description: PPU Verification Script with Python Generation

# 1. Configuration
MODULE_NAME="ppu"
TB_MODULE="${MODULE_NAME}_tb"
SIM_OUT="src/sim/${MODULE_NAME}_sim.out"
VCD_FILE="ppu_verify.vcd"

# 2. Generate Data
echo "[1/3] Generating Test Vectors (Python)..."
python src/scripts/gen_vectors_ppu.py

if [ $? -ne 0 ]; then
    echo "❌ Python script failed."
    exit 1
fi

# 3. Compile
echo "[2/3] Compiling RTL..."
iverilog -g2005-sv -I src/rtl -o ${SIM_OUT} \
    src/rtl/params.vh \
    src/rtl/${MODULE_NAME}.v \
    src/tb/${TB_MODULE}.v

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