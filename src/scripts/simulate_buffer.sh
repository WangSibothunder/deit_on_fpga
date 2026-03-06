MODULE_NAME="input_buffer_ctrl"
SIM_OUT="src/sim/buffer_sim.out"

echo "[1/2] Compiling ${MODULE_NAME}..."

iverilog -g2005-sv -I src/rtl -o ${SIM_OUT} \
    src/rtl/input_buffer_ctrl.v \
    src/tb/input_buffer_ctrl_tb.v

if [ $? -ne 0 ]; then
    echo "Compilation Failed!"
    exit 1
fi

echo "[2/2] Running Simulation..."
vvp ${SIM_OUT}

# Optional: Auto-open wave
gtkwave buffer_verify.vcd &
