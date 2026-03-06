#!/bin/bash

# Clean previous output
rm -rf src/data/test_data_core/*

echo "[1/3] Generating Test Vectors (Chinese Comments)..."
python src/scripts/gen_vectors_core_cn.py

if [ $? -ne 0 ]; then
    echo "❌ Python Script Failed"
    exit 1
fi

echo "[2/3] Compiling RTL & Testbench..."
# 注意: 我们需要编译所有相关文件
iverilog -g2005-sv -I src/rtl -o src/sim/core_sys_sim.out \
    src/rtl/params.vh \
    src/rtl/pe.v \
    src/rtl/single_column_bank.v \
    src/rtl/accumulator_bank.v \
    src/rtl/systolic_array.v \
    src/rtl/global_controller.v \
    src/rtl/deit_core.v \
    src/tb/deit_core_verify_tb_v2.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation Failed"
    exit 1
fi

echo "[3/3] Running System Simulation..."
vvp src/sim/core_sys_sim.out

# Open Waveform if needed
gtkwave core_verify_v3.vcd &