#!/bin/bash

# 通用Verilog仿真脚本
# 使用方法：./run_simulation.sh <module_name>
# 例如：./run_simulation.sh pe

if [ $# -eq 0 ]; then
    echo "错误: 请提供模块名称作为参数"
    echo "使用方法: ./run_simulation.sh <module_name>"
    echo "例如: ./run_simulation.sh pe"
    exit 1
fi

MODULE_NAME=$1
SIM_OUT="${MODULE_NAME}_sim.out"
TB_FILE="${MODULE_NAME}_tb.v"
VCD_FILE="${MODULE_NAME}_check.vcd"

echo "开始编译和仿真模块: $MODULE_NAME"

# 编译Verilog文件
echo "正在编译..."
iverilog -o $SIM_OUT params.vh ${MODULE_NAME}.v $TB_FILE
if [ $? -ne 0 ]; then
    echo "编译失败！"
    exit 1
fi

echo "编译成功，生成 $SIM_OUT"

# 运行仿真
echo "正在运行仿真..."
vvp $SIM_OUT
if [ $? -ne 0 ]; then
    echo "仿真运行失败！"
    exit 1
fi

echo "仿真完成，输出保存到 $VCD_FILE"

# 启动GTKWave查看波形（如果已安装）
if command -v gtkwave &> /dev/null; then
    echo "启动GTKWave查看波形..."
    gtkwave $VCD_FILE &
else
    echo "GTKWave未安装或不在PATH中，跳过波形查看"
    echo "你可以手动运行 'gtkwave $VCD_FILE' 来查看波形"
fi

echo "任务完成！"