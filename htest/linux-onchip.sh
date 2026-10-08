#!/usr/bin/env bash
# soc 的 Linux 层：从接力起到 shell 时存下的断点（build/linux-run/linux.ckpt）接着跑，SD 卡上放 sw/ 下的三个片上脚本，
# 在真的 Linux 里各跑一遍：xio.sh 读地址窗的标识，serdes.sh 片内自环跑一秒 PRBS 零误码，clkctl.sh 设分频再读回。
# 用法：linux-onchip.sh <输出目录> <黑盒仓> <to2610-kvc 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
R=$PWD/build/linux-run
rm -rf "$O"
mkdir -p "$O"
for f in linux.ckpt linux.ckpt.tb Vtb linux.flash; do
  [ -s "$R/$f" ] || { echo "build/linux-run 里没有 $f：接力还没起到 shell"; exit 1; }
done
chmod +x "$R/Vtb"
python3 "$K/htest/sdimg.py" "$O/sd.img" sw/xio.sh sw/clkctl.sh sw/serdes.sh
t0=$SECONDS
rc=0
"$R/Vtb" +flash="$R/linux.flash@0" +restore="$R/linux.ckpt" +pace=600000 +max=6000000000 +beat=500000000 \
  +sd="$O/sd.img" +script=htest/linux/onchip.script > "$O/onchip.log" 2> "$O/onchip.err" || rc=$?
tail -n 3 "$O/onchip.err"
python3 "$L/htest/junit.py" "$O/results.xml" \
  "onchip=$rc:$((SECONDS - t0)):sw/ 下三个片上脚本在这一颗的 Linux 里各跑一遍：地址窗标识、SerDes 片内自环一秒零误码、时钟分频设了再读回"
exit $rc
