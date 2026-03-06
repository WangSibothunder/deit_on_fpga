@echo off
setlocal

set MODULE=deit_accelerator_top
set TB_MODULE=%MODULE%_tb
set SIM_OUT=src\sim\%MODULE%_sim.out
set VCD_FILE=src/sim/top_verify.vcd

REM Init conda env
call G:\anaconda\Scripts\conda.exe activate pytorch
if errorlevel 1 (
  echo [WARN] Conda activate failed, continuing with system python.
)

REM 1. Compile
echo [1/3] Compiling RTL ^& Testbench...
iverilog -g2005-sv -I src\rtl -o %SIM_OUT% ^
  src\rtl\params.vh ^
  src\rtl\pe.v ^
  src\rtl\single_column_bank.v ^
  src\rtl\accumulator_bank.v ^
  src\rtl\systolic_array.v ^
  src\rtl\input_buffer_ctrl.v ^
  src\rtl\weight_buffer_ctrl.v ^
  src\rtl\global_controller.v ^
  src\rtl\deit_core.v ^
  src\rtl\ppu.v ^
  src\rtl\axi_lite_control.v ^
  src\rtl\output_buffer_ctrl.v ^
  src\rtl\%MODULE%.v ^
  src\tb\%TB_MODULE%.v

if errorlevel 1 (
  echo [ERROR] Compilation Failed
  exit /b 1
)

REM 2. Case 1: KV projection (M=197, K=192, N=384)
echo [2/3] Case1: KV Projection (197x192 * 192x384)
python src\scripts\gen_vectors_top.py --m 197 --k 192 --n 384
if errorlevel 1 (
  echo [ERROR] Python Script Failed (Case1)
  exit /b 1
)
vvp %SIM_OUT%
if errorlevel 1 (
  echo [ERROR] Simulation Runtime Failed (Case1)
  exit /b 1
)

REM 3. Case 2: S = K * V^T  (M=197, K=64, N=197)
echo [3/3] Case2: S=K*V^T (197x64 * 64x197)
python src\scripts\gen_vectors_top.py --m 197 --k 64 --n 197
if errorlevel 1 (
  echo [ERROR] Python Script Failed (Case2)
  exit /b 1
)
vvp %SIM_OUT%
if errorlevel 1 (
  echo [ERROR] Simulation Runtime Failed (Case2)
  exit /b 1
)

REM Optional: open waveform
REM start "" gtkwave %VCD_FILE%

echo [OK] System Verification Complete.
endlocal
