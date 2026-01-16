#!/bin/bash

# 1. Environment Setup
echo "[1/4] Setting up environment..."
rm -rf src/test_data_core
rm -f src/core_fix.out core_verify.vcd

# 2. Generate Golden Vectors (Python)
echo "[2/4] Generating Blocked Matrix Data (M=36, K=24)..."
python src/gen_vectors_core_verify.py
if [ $? -ne 0 ]; then echo "Python script failed."; exit 1; fi

# 3. Compile RTL (SystemVerilog)
# Explicitly including the fixed global_controller.v and deit_core.v logic
echo "[3/4] Compiling RTL..."
iverilog -g2005-sv -I src \
    -o src/core_fix.out \
    src/params.vh \
    src/weight_buffer_ctrl.v \
    src/input_buffer_ctrl.v \
    src/accumulator_bank.v \
    src/single_column_bank.v \
    src/systolic_array.v \
    src/pe.v \
    src/global_controller.v \
    src/deit_core.v \
    src/deit_core_verify_tb_v5.sv

if [ $? -ne 0 ]; then echo "Compilation failed."; exit 1; fi

# 4. Run Simulation
echo "[4/4] Running Simulation..."
vvp src/core_fix.out

# 5. Waveform Hint
if [ -f "core_verify.vcd" ]; then
    echo "Waveform generated: core_verify.vcd"
    
    echo "To view: gtkwave core_verify.vcd"
    gtkwave core_verify.vcd
fi