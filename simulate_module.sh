#!/bin/bash

# 快速仿真脚本 - 直接修改模块名称运行
# 只需要修改下面的 MODULE_NAME 变量即可

MODULE_NAME="systolic_array"  # <<< 修改这里为你要仿真的模块名称 >>>

SIM_OUT="${MODULE_NAME}_sim.out"
TB_FILE="${MODULE_NAME}_tb.v"
VCD_FILE="${MODULE_NAME}_check.vcd"

echo "开始编译和仿真模块: $MODULE_NAME"

# 编译Verilog文件
echo "正在编译..."
# 根据需要编译的模块添加依赖文件
cd src
if [ "$MODULE_NAME" == "systolic_array" ]; then
    iverilog -o ../$SIM_OUT params.vh pe.v ${MODULE_NAME}.v $TB_FILE
elif [ "$MODULE_NAME" == "pe" ]; then
    iverilog -o ../$SIM_OUT params.vh ${MODULE_NAME}.v $TB_FILE
else
    iverilog -o ../$SIM_OUT params.vh ${MODULE_NAME}.v $TB_FILE
fi
cd ..
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