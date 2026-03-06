@echo off
setlocal

set MODULE=deit_accelerator_top
set TB_MODULE=deit_accelerator_top_tb_dual
set SIM_OUT=src\sim\deit_accelerator_top_dual_sim.out
set VCD_FILE=src/sim/top_verify_dual.vcd
set CONDA=G:\anaconda\Scripts\conda.exe
set PYTHON_CMD=python

REM Prefer conda run if available
if exist "%CONDA%" (
  "%CONDA%" run -n pytorch python -V >nul 2>&1
  if errorlevel 1 (
    echo [WARN] conda run failed, using system python.
  ) else (
    set PYTHON_CMD="%CONDA%" run -n pytorch python
  )
) else (
  echo [WARN] conda.exe not found, using system python.
)

REM 1. Generate vectors (dual cases)
echo [1/3] Generating vectors (case1 + case2)...
%PYTHON_CMD% src\scripts\gen_vectors_dual.py
if errorlevel 1 (
  echo [ERROR] Python Script Failed
  exit /b 1
)

REM 2. Compile
echo [2/3] Compiling RTL ^& Testbench...
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

REM 3. Run simulation
echo [3/3] Running dual-case simulation...
vvp %SIM_OUT%
if errorlevel 1 (
  echo [ERROR] Simulation Runtime Failed
  exit /b 1
)

REM Optional: open waveform
REM start "" gtkwave %VCD_FILE%

echo [OK] Dual-case Verification Complete.
endlocal
