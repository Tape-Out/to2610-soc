#!/usr/bin/env bash
# 拼出这一颗的源码树 build/src：从黑盒仓拼好的那份 KianV SoC 源码（上游加它的补丁）起，套上 patch/soc.patch（开地址窗），
# 再放进息壤把 soc-io 装配出来的外设块、serdes 仓的那几个模块与本仓 hwsrc 里的模块。上游子模块不动。
# 用法：setup.sh <gf180mcu-kianv-rv32ima-sv32 仓> [serdes 仓]，后一个不给就取前一个旁边的。
# 息壤的调用方式由任务环境里的 $XIRANG 给
set -euo pipefail
cd "$(dirname "$0")/.."
K=$(realpath "$1")
D=$(realpath "${2:-$(dirname "$K")/serdes}")
rm -rf build/src build/io
mkdir -p build
bash "$K/htest/setup.sh" > /dev/null
cp -r "$K/build/src" build/src
patch -s -p1 -d build < patch/soc.patch
# soc-io 是本仓里的一个包，不在工作区的顶层：把本仓加进搜索路径
$XIRANG -p "$PWD" asic soc-io --no-run -o build/io > build/io.log 2>&1 || { tail -n 20 build/io.log; exit 1; }
cp build/io/to2610_soc_io.v "$D"/hwsrc/serdes_*.v hwsrc/*.v build/src/
echo "build/src：$(find build/src -name '*.v' -o -name '*.sv' | wc -l) 个源文件"
