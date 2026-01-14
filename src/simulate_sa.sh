#!/bin/bash

# 1. 重新生成随机测试数据 (确保 Python 脚本正确)
echo "[1/4] Generating Logic Vectors..."
python3 src/gen_vectors.py

# 2. 编译 RTL (包含新的 TB)
echo "[2/4] Compiling Verilog..."
# 注意: 我们只编译阵列相关的底层文件，不包含 controller 和 core
iverilog -o src/systolic_sim.out \
    src/params.vh \
    src/pe.v \
    src/systolic_array.v \
    src/systolic_array_tb.v

if [ $? -ne 0 ]; then
    echo "Compilation Failed!"
    exit 1
fi

# 3. 运行仿真
echo "[3/4] Running Simulation..."
vvp src/systolic_sim.out

# 4. 打开波形 (Optional)
echo "[4/4] Opening Waveform..."
# 判断系统类型，如果是 macOS 则使用 open -a，Linux 直接 gtkwave
if [[ "$OSTYPE" == "darwin"* ]]; then
    # 尝试在后台打开 GTKWave，如果安装了的话
    if command -v gtkwave &> /dev/null; then
        gtkwave src/systolic_array.vcd &
    else
        echo "GTKWave not found in path. Please verify waveform manually: src/systolic_array.vcd"
    fi
else
    gtkwave src/systolic_array.vcd &
fi