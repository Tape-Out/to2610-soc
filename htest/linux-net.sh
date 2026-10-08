#!/usr/bin/env bash
# soc 的网络：从接力起到 shell 时存的断点（build/linux-run）接着跑 to2610-kvc 的网络四段（htest/linux-layers.sh 的 net）。
# Frame 形态没有以太网，入网走 SPI 网卡口接 W5500，与 to2610-kvc 同一组引脚、同一份镜像，用例原样复用。
# 用法：linux-net.sh <输出目录> <黑盒仓> <to2610-kvc 仓> <to2610-router 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
RT=$(realpath "$4")
R=$PWD/build/linux-run
[ -s "$R/linux.ckpt" ] || { echo "build/linux-run 里没有 linux.ckpt：接力还没起到 shell"; exit 1; }
CKPT=$R LAYERS=net exec bash "$L/htest/linux-layers.sh" "$O" "$K" "$RT"
