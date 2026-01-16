#!/bin/bash
# -----------------------------------------------------------------------------
# Script: simulate_top.sh
# 描述: 编译并仿真 DeiT 加速器顶层 (System Level)
# -----------------------------------------------------------------------------

MODULE="deit_accelerator_top"
TB_MODULE="${MODULE}_tb"
SIM_OUT="src/${MODULE}_sim.out"
VCD_FILE="top_verify.vcd"

# 1. Generate Vectors
echo "[1/3] Generating System Vectors..."
python src/gen_vectors_top.py

if [ $? -ne 0 ]; then
    echo "❌ Python Script Failed"
    exit 1
fi

# 2. Compile
echo "[2/3] Compiling RTL & Testbench..."

iverilog -g2005-sv -I src -o ${SIM_OUT} \
    src/params.vh \
    src/pe.v \
    src/single_column_bank.v \
    src/accumulator_bank.v \
    src/systolic_array.v \
    src/input_buffer_ctrl.v \
    src/weight_buffer_ctrl.v \
    src/global_controller.v \
    src/deit_core.v \
    src/ppu.v \
    src/axi_lite_control.v \
    src/${MODULE}.v \
    src/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation Failed"
    exit 1
fi

# 3. Simulate
echo "[3/3] Running Simulation..."
vvp ${SIM_OUT}
gtkwave ${VCD_FILE} &
if [ $? -ne 0 ]; then
    echo "❌ Simulation Runtime Failed"
    exit 1
fi

echo "✅ System Verification Complete."