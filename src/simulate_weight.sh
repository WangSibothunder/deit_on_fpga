#!/bin/bash

# -----------------------------------------------------------------------------
# Script: simulate_weight.sh
# Description: Standardized simulation script for Weight Buffer Controller
# Usage: ./src/simulate_weight.sh
# -----------------------------------------------------------------------------

# 1. Configuration
MODULE_NAME="weight_buffer_ctrl"
TB_MODULE="${MODULE_NAME}_tb"
SIM_OUT="src/${MODULE_NAME}_sim.out"
VCD_FILE="weight_verify.vcd"

# 2. Compilation
echo "[1/3] Compiling ${MODULE_NAME}..."

iverilog -g2005-sv -I src -o ${SIM_OUT} \
    src/params.vh \
    src/${MODULE_NAME}.v \
    src/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "? Compilation FAILED."
    exit 1
fi

# 3. Simulation
echo "[2/3] Running Simulation..."
vvp ${SIM_OUT}

if [ $? -ne 0 ]; then
    echo "? Simulation Runtime FAILED."
    exit 1
fi

# 4. Waveform
echo "[3/3] Checking Waveform..."
if command -v gtkwave &> /dev/null; then
    if [ -f "${VCD_FILE}" ]; then
        # Check OS for background run
        if [[ "$OSTYPE" == "darwin"* ]]; then
            gtkwave ${VCD_FILE} &
        else
            gtkwave ${VCD_FILE} &
        fi
    fi
fi

echo "? Task Complete."