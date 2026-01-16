#!/bin/bash
# -----------------------------------------------------------------------------
# Script: simulate_controller.sh
# -----------------------------------------------------------------------------

MODULE_NAME="global_controller"
TB_MODULE="${MODULE_NAME}_tb"
SIM_OUT="src/${MODULE_NAME}_sim.out"
VCD_FILE="controller_verify.vcd"

echo "[1/3] Compiling ${MODULE_NAME}..."

iverilog -g2005-sv -I src -o ${SIM_OUT} \
    src/${MODULE_NAME}.v \
    src/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation FAILED."
    exit 1
fi

echo "[2/3] Running Simulation..."
vvp ${SIM_OUT}

if [ $? -ne 0 ]; then
    echo "❌ Simulation Runtime FAILED."
    exit 1
fi

echo "[3/3] Checking Waveform..."
gtkwave ${VCD_FILE} &

echo "✅ Controller Verified."