#!/bin/bash
# 保存为 src/simulate_axi.sh 并 chmod +x

echo "Compiling AXI Lite Control..."
iverilog -g2005-sv -o axi_sim.out src/axi_lite_control.v src/axi_lite_control_tb.v

if [ $? -eq 0 ]; then
    echo "Running Simulation..."
    vvp axi_sim.out
    
    # 自动打开波形 (如果安装了 GTKWave)
    if command -v gtkwave &> /dev/null; then
        echo "Opening Waveform..."
        gtkwave axi_lite_verify.vcd &
    fi
else
    echo "Compilation Failed!"
fi