#!/bin/bash

# 1. 设置环境
# 确保 test_data 目录存在
mkdir -p src/test_data

# 2. 生成 Python 向量
echo "[1/3] Generating Test Vectors..."
python3 src/gen_vectors.py

if [ $? -ne 0 ]; then
    echo "Python script failed."
    exit 1
fi

# 3. 编译 Verilog
echo "[2/3] Compiling RTL..."
MODULE_NAME="deit_core_verify"
SIM_OUT="src/${MODULE_NAME}_sim.out"
TB_FILE="src/deit_core_verify_tb.v"

# 编译所有相关文件
iverilog -g2005-sv -o $SIM_OUT \
    src/params.vh \
    src/pe.v \
    src/single_column_bank.v \
    src/global_controller.v \
    src/systolic_array.v \
    src/accumulator_bank.v \
    src/deit_core.v \
    $TB_FILE

if [ $? -ne 0 ]; then
    echo "Verilog compilation failed."
    exit 1
fi

# 4. 运行仿真
echo "[3/3] Running Simulation..."
vvp $SIM_OUT

# 5. 打开波形提示
echo ""
echo "Done. To view waveforms:"
echo "gtkwave core_verify.vcd"