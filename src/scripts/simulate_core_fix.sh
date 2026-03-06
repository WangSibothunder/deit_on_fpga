#!/bin/bash

# 1. Environment Setup
echo "[1/4] Setting up environment..."
rm -rf src/data/test_data_core
rm -f src/sim/core_fix.out core_verify.vcd

# 2. Generate Golden Vectors (Python)
echo "[2/4] Generating Blocked Matrix Data (M=36, K=24)..."
python src/scripts/gen_vectors_core_verify.py
if [ $? -ne 0 ]; then echo "Python script failed."; exit 1; fi

# 3. Compile RTL (SystemVerilog)
# Explicitly including the fixed global_controller.v and deit_core.v logic
echo "[3/4] Compiling RTL..."
iverilog -g2005-sv -I src/rtl \
    -o src/sim/core_fix.out \
    src/rtl/params.vh \
    src/rtl/weight_buffer_ctrl.v \
    src/rtl/input_buffer_ctrl.v \
    src/rtl/accumulator_bank.v \
    src/rtl/single_column_bank.v \
    src/rtl/systolic_array.v \
    src/rtl/pe.v \
    src/rtl/global_controller.v \
    src/rtl/deit_core.v \
    src/tb/deit_core_verify_tb_v5.sv

if [ $? -ne 0 ]; then echo "Compilation failed."; exit 1; fi

# 4. Run Simulation
echo "[4/4] Running Simulation..."
vvp src/sim/core_fix.out

# 5. Waveform Hint
if [ -f "core_verify.vcd" ]; then
    echo "Waveform generated: core_verify.vcd"
    
    echo "To view: gtkwave core_verify.vcd"
    gtkwave core_verify.vcd
fi