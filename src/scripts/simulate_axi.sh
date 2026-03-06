#!/bin/bash
# Ϊ src/simulate_axi.sh  chmod +x

echo "Compiling AXI Lite Control..."
iverilog -g2005-sv -o src/sim/axi_sim.out src/rtl/axi_lite_control.v src/tb/axi_lite_control_tb.v

if [ $? -eq 0 ]; then
    echo "Running Simulation..."
    vvp src/sim/axi_sim.out
    
    # Զ򿪲 (װ GTKWave)
    if command -v gtkwave &> /dev/null; then
        echo "Opening Waveform..."
        gtkwave axi_lite_verify.vcd &
    fi
else
    echo "Compilation Failed!"
fi
