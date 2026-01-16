#!/bin/bash
MODULE_NAME="accumulator_bank"
TB_MODULE="accumulator_tb"
SIM_OUT="src/accum_sim.out"

echo "[1/3] Compiling Accumulator Suite..."
iverilog -g2005-sv -I src -o ${SIM_OUT} \
    src/params.vh \
    src/single_column_bank.v \
    src/${MODULE_NAME}.v \
    src/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation FAILED."
    exit 1
fi

echo "[2/3] Running Simulation..."
vvp ${SIM_OUT}
gtkwave accum_deep_verify.vcd &
echo "[3/3] Task Complete."