#!/bin/bash

# Clean previous output
rm -rf src/test_data_core/*

echo "[1/3] Generating Test Vectors (Chinese Comments)..."
python src/gen_vectors_core_cn.py

if [ $? -ne 0 ]; then
    echo "❌ Python Script Failed"
    exit 1
fi

echo "[2/3] Compiling RTL & Testbench..."
# 注意: 我们需要编译所有相关文件
iverilog -g2005-sv -I src -o src/core_sys_sim.out \
    src/params.vh \
    src/pe.v \
    src/single_column_bank.v \
    src/accumulator_bank.v \
    src/systolic_array.v \
    src/global_controller.v \
    src/deit_core.v \
    src/deit_core_verify_tb_v2.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation Failed"
    exit 1
fi

echo "[3/3] Running System Simulation..."
vvp src/core_sys_sim.out

# Open Waveform if needed
gtkwave core_verify_v3.vcd &