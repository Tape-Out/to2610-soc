#!/bin/sh
# 在芯片上的 Linux 里用（to2610-kvc 的镜像，busybox 带 devmem）：经 /dev/mem 读写地址窗里的东西。
# 外设的寄存器偏移在各自仓的 regmap.yaml 里，ran gen <名字> 出 C 头文件。
# 用法：xio.sh id                 读标识，应是 0x534F4331
#       xio.sh pads [数]          读或写 PADSEL（数用主机上的 padsel.py 算）
#       xio.sh r <偏移>           读窗里的一个字，偏移从 0x4000_0000 算起
#       xio.sh w <偏移> <数>      写窗里的一个字
set -eu
case "${1:-}" in
  id) devmem 0x40030000 32 ;;
  pads)
    [ $# -ge 2 ] && devmem 0x40030004 32 "$2"
    devmem 0x40030004 32
    ;;
  r) devmem $((0x40000000 + $2)) 32 ;;
  w) devmem $((0x40000000 + $2)) 32 "$3" ;;
  *)
    sed -n '2,8p' "$0"
    exit 1
    ;;
esac
