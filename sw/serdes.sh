#!/bin/sh
# 在芯片上的 Linux 里用（busybox 带 devmem）：SerDes 的自环、误码测试与收发字节。
# 寄存器在 0x4001_0000，各位的意思见 serdes 仓 hwsrc/serdes_apb.v 开头。
# 走焊盘之前先把 x4、x5 选给它：主机上 padsel.py serdes 算出数，芯片上 xio.sh pads <数>。
# 线速率是线路时钟的四分之一：取系统时钟时 12.5 Mbit/s，取 PLL 那一路时由 clkctl.sh 定。
# 用法：serdes.sh stat             对齐、锁定、队列的状态
#       serdes.sh loop [秒]        片内自环跑 PRBS，报字节数与误码数；不写是 2 秒
#       serdes.sh prbs [秒]        同上，走焊盘：自己的 TX 接回 RX，或两颗交叉对接、两边都跑这一条
#       serdes.sh inject           在线上翻一位（跑着 loop 或 prbs 时用，下一次的误码数该多出来）
#       serdes.sh tx <字节>...     发字节（十六进制），对面用 rx 收
#       serdes.sh rx               把收到的都读出来
#       serdes.sh off              关掉
set -eu
B=0x40010000
DM=${DEVMEM:-devmem}
rd() { $DM $((B + $1)) 32; }
wr() { $DM $((B + $1)) 32 "$2" > /dev/null; }

wait_for() {
  n=0
  until [ $(($(rd 12) & $1)) = $(($2)) ]; do
    n=$((n + 1))
    [ $n -lt 200 ] || return 1
  done
}

stat() {
  s=$(rd 12)
  echo "ALIGNED=$((s & 1)) LOCKED=$((s >> 1 & 1)) TX_FULL=$((s >> 2 & 1)) RX_VALID=$((s >> 3 & 1)) RX_OVER=$((s >> 4 & 1))"
}

# 开起来，等对齐与锁定，清零，跑够时间，抓一次计数
count() {
  wr 4 "$1"
  wait_for 3 3 || { echo "没对齐或没锁上：$(stat)" >&2; exit 1; }
  wr 8 2
  sleep "$2"
  wr 8 4
  wait_for 0x20 0 || { echo "抓计数没回来" >&2; exit 1; }
  bad=$(rd 28)
  echo "字节 $(($(rd 36))) 误码 $(($(rd 40))) 符号 $(($(rd 24))) 码字不合法 $((bad & 0xffff)) 游程差不对 $((bad >> 16)) 重新对齐 $(($(rd 32)))"
}

case "${1:-}" in
  stat) stat ;;
  loop) count 0xf "${2:-2}" ;;
  prbs) count 0xd "${2:-2}" ;;
  inject) wr 8 1 ;;
  tx)
    shift
    c=$(rd 4)
    [ $((c & 1)) = 1 ] || wr 4 1
    for b in "$@"; do
      wait_for 4 0 || { echo "发的队列一直是满的" >&2; exit 1; }
      wr 16 $((0x$b))
    done
    ;;
  rx)
    c=$(rd 4)
    [ $((c & 1)) = 1 ] || wr 4 1
    while :; do
      v=$(rd 20)
      [ $((v >> 31 & 1)) = 1 ] || break
      printf '%02x%s%s ' $((v & 0xff)) "$([ $((v >> 8 & 1)) = 1 ] && echo K)" "$([ $((v >> 9 & 1)) = 1 ] && echo '!')"
    done
    echo
    ;;
  off) wr 4 0 ;;
  *)
    sed -n '2,12p' "$0"
    exit 1
    ;;
esac
