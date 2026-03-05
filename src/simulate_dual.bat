@echo off
setlocal

set MODULE=deit_accelerator_top
set TB_MODULE=deit_accelerator_top_tb_dual
set SIM_OUT=src\deit_accelerator_top_dual_sim.out
set VCD_FILE=top_verify.vcd
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
%PYTHON_CMD% src\gen_vectors_dual.py
if errorlevel 1 (
  echo [ERROR] Python Script Failed
  exit /b 1
)

REM 2. Compile
echo [2/3] Compiling RTL ^& Testbench...
iverilog -g2005-sv -I src -o %SIM_OUT% ^
  src\params.vh ^
  src\pe.v ^
  src\single_column_bank.v ^
  src\accumulator_bank.v ^
  src\systolic_array.v ^
  src\input_buffer_ctrl.v ^
  src\weight_buffer_ctrl.v ^
  src\global_controller.v ^
  src\deit_core.v ^
  src\ppu.v ^
  src\axi_lite_control.v ^
  src\output_buffer_ctrl.v ^
  src\%MODULE%.v ^
  src\%TB_MODULE%.v

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
