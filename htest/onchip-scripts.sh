#!/usr/bin/env bash
# sw/ 里在芯片上用的几个脚本（clkctl.sh、serdes.sh、xio.sh）与 padsel.py，在主机上拿假的 devmem 过一遍：
# 原样要过，再埋六处错，每处都要红。假的 devmem 是照寄存器说明另写的模型（htest/onchip-scripts/devmem），
# 经 DEVMEM 交给脚本：busybox 的 sh 先找自带的小程序再找 PATH，PATH 里放一个同名的顶不掉它。
# 芯片上的 sh 是 busybox 的；这里用系统的 sh（dash），主机上有 busybox 时再用它跑一遍原样的。
# 用法：onchip-scripts.sh <输出目录>
set -u
out=$1
here=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"

# 跑一遍全部检查。$1 是脚本所在的目录，$2 是用哪个 sh，$3 是状态文件。第一处不对就返回 1，并说是哪一处
run() {
  local sw=$1 sh=$2 st=$3 got rc
  rm -f "$st"
  export DEVMEM_STATE=$st DEVMEM="$here/htest/onchip-scripts/devmem"
  unset DEVMEM_WIRED
  want() {
    local what=$1 pat=$2
    shift 2
    got=$("$@" 2>&1)
    rc=$?
    if [ $rc -ne 0 ] || ! grep -q -- "$pat" <<< "$got"; then
      echo "FAIL $what：rc=$rc，要有「$pat」，得到：$(tr '\n' '|' <<< "$got" | cut -c1-200)"
      return 1
    fi
  }
  refuse() {
    local what=$1 pat=$2
    shift 2
    got=$("$@" 2>&1)
    rc=$?
    if [ $rc -eq 0 ] || ! grep -q -- "$pat" <<< "$got"; then
      echo "FAIL $what：该拒绝（rc=$rc），要有「$pat」，得到：$(tr '\n' '|' <<< "$got" | cut -c1-200)"
      return 1
    fi
  }
  want "复位后的时钟" "量到 12500 kHz" $sh $sw/clkctl.sh show || return 1
  want "复位后的设置" "N=32 x2=0 OD=8 BP=1 EN=0" $sh $sw/clkctl.sh show || return 1
  want "N 32、OD 8" "量到 50000 kHz" $sh $sw/clkctl.sh pll 32 || return 1
  want "N 20、x2、OD 8" "量到 62500 kHz" $sh $sw/clkctl.sh pll 20 x2 8 || return 1
  want "N 32、OD 4 的预期" "该是 100000 kHz（VCO 800000 kHz）" $sh $sw/clkctl.sh pll 32 4 || return 1
  want "D 1" "量到 50000 kHz" $sh $sw/clkctl.sh div 1 || return 1
  want "D 0" "量到 100000 kHz" $sh $sw/clkctl.sh div 0 || return 1
  want "N 16 不合法" "量到 0 kHz" $sh $sw/clkctl.sh pll 16 || return 1
  want "N 16 的预期" "该是 0（VCO 400000 kHz" $sh $sw/clkctl.sh show || return 1
  refuse "没有时钟不许切" "不切" $sh $sw/clkctl.sh src pll || return 1
  want "不合法之后重设" "量到 50000 kHz" $sh $sw/clkctl.sh pll 32 || return 1
  want "切到 PLL" "" $sh $sw/clkctl.sh src pll || return 1
  want "送到脚上" "" $sh $sw/clkctl.sh out on || return 1
  want "SRC 与 OUT" "D=0 OUT=1 SRC=1" $sh $sw/clkctl.sh show || return 1
  want "关掉 OUT" "" $sh $sw/clkctl.sh out off || return 1
  want "切回系统时钟" "" $sh $sw/clkctl.sh src sys || return 1
  want "SRC 与 OUT 都关了" "D=0 OUT=0 SRC=0" $sh $sw/clkctl.sh show || return 1
  want "旁路" "量到 12500 kHz" $sh $sw/clkctl.sh bypass || return 1
  want "单测频" "^12500$" $sh $sw/clkctl.sh freq || return 1

  want "先翻一位" "" $sh $sw/serdes.sh inject || return 1
  want "自环" "字节 31250 误码 0 " $sh $sw/serdes.sh loop 0 || return 1
  refuse "没接线时走焊盘" "没对齐或没锁上" $sh $sw/serdes.sh prbs 0 || return 1
  export DEVMEM_WIRED=1
  want "接了线走焊盘" "字节 31250 误码 0 " $sh $sw/serdes.sh prbs 0 || return 1
  $sh $sw/serdes.sh prbs 3 > "$st.bg" 2>&1 &
  sleep 1.5
  want "跑着的时候翻一位" "" $sh $sw/serdes.sh inject || return 1
  wait
  grep -q "误码 1 " "$st.bg" || { echo "FAIL 翻了一位，误码数不是 1：$(cat "$st.bg")"; return 1; }
  want "关掉" "" $sh $sw/serdes.sh off || return 1
  want "发四个字节" "" $sh $sw/serdes.sh tx 21 54 87 ba || return 1
  want "状态" "ALIGNED=1 LOCKED=1 TX_FULL=0 RX_VALID=1" $sh $sw/serdes.sh stat || return 1
  want "收四个字节" "^21 54 87 ba $" $sh $sw/serdes.sh rx || return 1
  want "收空了" "^$" $sh $sw/serdes.sh rx || return 1

  want "标识" "0x534F4331" $sh $sw/xio.sh id || return 1
  want "选脚" "PADSEL = 0x00000f00" python3 $sw/padsel.py serdes || return 1
  want "写 PADSEL" "0x00000F00" $sh $sw/xio.sh pads 0x00000f00 || return 1
  want "窗里写一个字" "" $sh $sw/xio.sh w 0x20004 0x1234 || return 1
  want "窗里读回来" "0x00001234" $sh $sw/xio.sh r 0x20004 || return 1
  python3 -c "import json, sys; sys.exit(json.load(open('$st'))['misuse'])" || { echo "FAIL 脚本没照 PLL 的规矩走（开着 EN 改设置，或没有时钟就切过去）"; return 1; }
  echo "PASS"
}

SH=sh
run "$here/sw" $SH "$out/state" > "$out/clean.log" 2>&1
rc=$?
cat "$out/clean.log"
[ $rc -eq 0 ] || { echo "原样没过"; exit 1; }
if command -v busybox > /dev/null; then
  run "$here/sw" "busybox sh" "$out/state" > "$out/busybox.log" 2>&1
  rc=$?
  [ $rc -eq 0 ] || { cat "$out/busybox.log"; echo "busybox 的 sh 下没过"; exit 1; }
  echo "busybox 的 sh 下也过"
fi

# 名字~文件~sed 表达式
FAULTS='en~clkctl.sh~s/wr 4 \$((v | 1 << 17))/wr 4 $((v | 1 << 16))/
seq~clkctl.sh~/^    wr 4 \$v$/d
od~clkctl.sh~s/c << 9/c << 8/
guard~clkctl.sh~s/\[ "\$(freq)" != 0 \] ||/false \&\&/
snap~serdes.sh~s/^  wr 8 4$/  wr 8 2/
clear~serdes.sh~/^  wr 8 2$/d'
bad=0
while IFS='~' read -r name file expr; do
  m=$out/mut-$name
  rm -rf "$m" && mkdir -p "$m"
  cp "$here"/sw/*.sh "$here"/sw/*.py "$m"/
  sed -i -e "$expr" "$m/$file"
  if cmp -s "$m/$file" "$here/sw/$file"; then
    echo "$name 没埋上"
    bad=1
    continue
  fi
  got=$(run "$m" $SH "$out/state-$name" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "$name 埋了错还是过"
    bad=1
  else
    echo "$name 红了：$(grep -a FAIL <<< "$got" | head -n 1 | cut -c1-150)"
  fi
done <<< "$FAULTS"
[ $bad -eq 0 ] || { echo "有埋错没被抓到"; exit 1; }
echo "片上脚本原样过，六处埋错都红"
