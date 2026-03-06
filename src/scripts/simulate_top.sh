#!/bin/bash
# -----------------------------------------------------------------------------
# Script: simulate_top.sh
# 描述: 编译并仿真 DeiT 加速器顶层 (System Level)
# -----------------------------------------------------------------------------

MODULE="deit_accelerator_top"
TB_MODULE="${MODULE}_tb"
SIM_OUT="src/sim/${MODULE}_sim.out"
VCD_FILE="src/sim/top_verify.vcd"
# 在Git Bash中初始化conda
eval "$(G:/anaconda/Scripts/conda.exe 'shell.bash' 'hook')"

# 激活pytorch环境
conda activate pytorch

# 1. Generate Vectors
echo "[1/3] Generating System Vectors..."
python src/scripts/gen_vectors_top.py

if [ $? -ne 0 ]; then
    echo "❌ Python Script Failed"
    exit 1
fi

# 2. Compile
echo "[2/3] Compiling RTL & Testbench..."

iverilog -g2005-sv -I src/rtl -o ${SIM_OUT} \
    src/rtl/params.vh \
    src/rtl/pe.v \
    src/rtl/single_column_bank.v \
    src/rtl/accumulator_bank.v \
    src/rtl/systolic_array.v \
    src/rtl/input_buffer_ctrl.v \
    src/rtl/weight_buffer_ctrl.v \
    src/rtl/global_controller.v \
    src/rtl/deit_core.v \
    src/rtl/ppu.v \
    src/rtl/axi_lite_control.v \
    src/rtl/output_buffer_ctrl.v \
    src/rtl/${MODULE}.v \
    src/tb/${TB_MODULE}.v

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