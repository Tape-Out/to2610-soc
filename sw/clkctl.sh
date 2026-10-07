#!/bin/sh
# 在芯片上的 Linux 里用（busybox 带 devmem）：设 PLL 的倍频与分频、量分出来的频率、切 SerDes 的线路时钟。
# 寄存器在 0x4005_0000，各位的意思见 hwsrc/clkctl.v 开头。PLL 只有 MPW 形态里有；Frame 形态里量到的恒是 0。
# 参考时钟是系统时钟的一半（25 MHz）。VCO = 25 MHz × N ×（x2 ? 2 : 1），要落在 500 至 1200 MHz：
# 不带 x2 时 N 取 20 至 48，带 x2 时取 17 至 24。PLL 出的是 VCO 除以 OD（1、2、4、8），后面再除以 2 ×（D + 1）。
# 用法：clkctl.sh show                 现在的设置与量到的频率
#       clkctl.sh pll <N> [x2] [OD]    设倍频（先关 EN、设好、再开），OD 不写是 8；设完量一次
#       clkctl.sh bypass               回到旁路：PLL 的输出就是参考时钟
#       clkctl.sh div <D>              后一级分频，除以 2 ×（D + 1）
#       clkctl.sh out on|off           分出来的时钟送不送到 clk_out 脚
#       clkctl.sh src pll|sys          SerDes 的线路时钟取哪一路；取 pll 之前那一路要量得到频率
#       clkctl.sh freq                 量一次，单位 kHz
set -eu
B=0x40050000
DM=${DEVMEM:-devmem}
SYS_KHZ=50000
rd() { $DM $((B + $1)) 32; }
wr() { $DM $((B + $1)) 32 "$2" > /dev/null; }

# 读一次把「有新结果」清掉，再等下一个窗口（65536 个系统时钟，一毫秒多）
freq() {
  rd 12 > /dev/null
  n=0
  while :; do
    v=$(rd 12)
    [ $((v >> 31 & 1)) = 1 ] && break
    n=$((n + 1))
    [ $n -lt 1000 ] || { echo "等不到新的测频结果" >&2; exit 1; }
  done
  echo $(((v & 0xffffff) * SYS_KHZ / 65536))
}

show() {
  p=$(rd 4)
  d=$(rd 8)
  n=$((p & 0xff))
  x2=$((p >> 8 & 1))
  od=$((1 << (p >> 9 & 3)))
  bp=$((p >> 16 & 1))
  en=$((p >> 17 & 1))
  dd=$((d & 0xff))
  vco=$((SYS_KHZ / 2 * n * (x2 + 1)))
  echo "PLL  N=$n x2=$x2 OD=$od BP=$bp EN=$en"
  echo "DIV  D=$dd OUT=$((d >> 16 & 1)) SRC=$((d >> 17 & 1))"
  if [ $bp = 1 ]; then
    echo "该是 $((SYS_KHZ / 2 / (2 * (dd + 1)))) kHz（旁路）"
  elif [ $en = 0 ]; then
    echo "该是 0（EN 没开）"
  elif [ $n -le 16 ] || [ $vco -lt 500000 ] || [ $vco -gt 1200000 ]; then
    echo "该是 0（VCO $vco kHz 不在 500 至 1200 MHz 里，或 N 不大于 16）"
  else
    echo "该是 $((vco / od / (2 * (dd + 1)))) kHz（VCO $vco kHz）"
  fi
  echo "量到 $(freq) kHz"
}

case "${1:-}" in
  show) show ;;
  freq) freq ;;
  pll)
    n=$2
    x2=0
    od=8
    shift 2
    for a in "$@"; do
      case "$a" in
        x2) x2=1 ;;
        1 | 2 | 4 | 8) od=$a ;;
        *) echo "不认识 $a" >&2; exit 1 ;;
      esac
    done
    case $od in 1) c=0 ;; 2) c=1 ;; 4) c=2 ;; 8) c=3 ;; esac
    v=$((n & 0xff | x2 << 8 | c << 9))
    wr 4 $v
    wr 4 $((v | 1 << 17))
    show
    ;;
  bypass)
    wr 4 $(($(rd 4) & 0x7ff | 1 << 16))
    show
    ;;
  div)
    wr 8 $(($(rd 8) & 0x30000 | $2 & 0xff))
    show
    ;;
  out)
    d=$(rd 8)
    case "$2" in
      on) wr 8 $((d | 1 << 16)) ;;
      off) wr 8 $((d & ~(1 << 16))) ;;
      *) echo "on 或 off" >&2; exit 1 ;;
    esac
    ;;
  src)
    d=$(rd 8)
    case "$2" in
      pll)
        [ "$(freq)" != 0 ] || { echo "PLL 那一路量不到时钟，不切（切过去线路这一侧就停了）" >&2; exit 1; }
        wr 8 $((d | 1 << 17))
        ;;
      sys) wr 8 $((d & ~(1 << 17))) ;;
      *) echo "pll 或 sys" >&2; exit 1 ;;
    esac
    ;;
  *)
    sed -n '2,13p' "$0"
    exit 1
    ;;
esac
