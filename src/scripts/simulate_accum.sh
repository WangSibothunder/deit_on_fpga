#!/bin/bash
MODULE_NAME="accumulator_bank"
TB_MODULE="accumulator_tb"
SIM_OUT="src/sim/accum_sim.out"

echo "[1/3] Compiling Accumulator Suite..."
iverilog -g2005-sv -I src/rtl -o ${SIM_OUT} \
    src/rtl/params.vh \
    src/rtl/single_column_bank.v \
    src/rtl/${MODULE_NAME}.v \
    src/tb/${TB_MODULE}.v

if [ $? -ne 0 ]; then
    echo "❌ Compilation FAILED."
    exit 1
fi

echo "[2/3] Running Simulation..."
vvp ${SIM_OUT}
gtkwave accum_deep_verify.vcd &
echo "[3/3] Task Complete."