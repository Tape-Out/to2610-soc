#!/usr/bin/env bash
# 引脚这一层的变异：把 hwsrc/soc_frame.v 里的一根脚接错（悬空、两根对调、拿错焊盘），重出 .v，
# xio 那一段里管这根脚的那一句要 BAD。脚本里的 expect 都拿掉、只留 done，让程序跑到底，看是哪几句红了。
# 跑到一半卡住、没到 done 的，整片测试照样是红的：管这根脚的那一句还没报 ok 就算抓到了。
# 在临时的工作区里做（别的仓软链接过来，本仓拷一份），不动真的仓。
# 用法：pin-faults.sh <输出目录> <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-kvc 仓>      PINS=名字,名字 只跑表里的这几条
set -u
cd "$(dirname "$0")/.."
here=$PWD
O=$(realpath -m "$1")
K=$(realpath "$2")
rm -rf "$O"
mkdir -p "$O/ws/to2610-soc" "$O/xio/inc"
# 照这次息壤的搜索路径去链：流水线上各个依赖不在本仓旁边
for r in $(grep -o -- '-p [^ ]*' <<< "$XIRANG" | cut -c4-) "$here/.."; do
  for d in "$r"/*/; do
    n=$(basename "$d")
    [ "$n" = to2610-soc ] || [ -e "$O/ws/$n" ] || ln -s "$(realpath "$d")" "$O/ws/$n"
  done
done
tar cf - --exclude=build --exclude=.git . | tar xf - -C "$O/ws/to2610-soc"
RAN="${XIRANG%% -p *} -p $O/ws"
R=$O/ws/to2610-soc

for ip in uart gpio timer wdt rtc i2c spi onew i2s can ps2 rng emac pwm crc; do
  $XIRANG gen "$ip" -o "$O/xio/gen/$ip" > /dev/null
  cp "$O/xio/gen/$ip/sw/$ip.h" "$O/xio/inc/"
done
make -s -C htest/xio O="$O/xio" HELLO="$K/htest/hello" || exit 1
echo "expect done" > "$O/script"

# 名字~sed 表达式~该红的那一句
FAULTS='sda~s/\.i2c_sda_i    (`PAD(5, 1, 1.b1))/.i2c_sda_i    (1'"'"'b1)/~i2c
scl~s/ow_pull, sda_pull, scl_pull,/ow_pull, scl_pull, sda_pull,/~i2c
canrx~s/\.can_rx       (`PAD(8, 1, 1.b1))/.can_rx       (1'"'"'b1)/~can
cantx~s/1.b0, can_tx, 1.b0, 1.b0, 1.b0, 1.b0, rts_n/1'"'"'b0, 1'"'"'b1, 1'"'"'b0, 1'"'"'b0, 1'"'"'b0, 1'"'"'b0, rts_n/~can
capt~s/\.timer_capt   ({1.b0, `PAD(11, 1, 1.b0)})/.timer_capt   (2'"'"'b00)/~capt
pwmrev~s/{wdt_rst_out, pwm\[3:0\],/{wdt_rst_out, pwm[0], pwm[1], pwm[2], pwm[3],/~pins
pwm02~s/{wdt_rst_out, pwm\[3:0\],/{wdt_rst_out, pwm[3], pwm[0], pwm[1], pwm[2],/~pins
wdt~s/{wdt_rst_out, pwm\[3:0\],/{1'"'"'b0, pwm[3:0],/~pins
rng~s/\.rng_noise    (`PAD(11, 3, 1.b0))/.rng_noise    (1'"'"'b0)/~rng
cs1~s/i2s_sck, cs_n\[1\], 1.b0, sd_tx/i2s_sck, 1'"'"'b1, 1'"'"'b0, sd_tx/~spics1
miso~s/({`PAD(3, 3, 1.b0), `PAD(2, 3, 1.b0)})/({`PAD(2, 3, 1'"'"'b0), `PAD(3, 3, 1'"'"'b0)})/~spi
rxd~s/\.uart1_rxd    (`PAD(1, 1, 1.b1))/.uart1_rxd    (`PAD(3, 1, 1'"'"'b1))/~uart
rmii~s/({`PAD(4, 2, 1.b0), `PAD(3, 2, 1.b0)})/({`PAD(3, 2, 1'"'"'b0), `PAD(4, 2, 1'"'"'b0)})/~emac
i2s~s/\.i2s_sd_i     (`PAD(10, 3, 1.b0))/.i2s_sd_i     (1'"'"'b0)/~i2s
sdrx~s/\.sd_rx        (`PAD(5, 3, 1.b0))/.sd_rx        (1'"'"'b0)/~sdpad
onew~s/\.onew_i       (`PAD(6, 1, 1.b1))/.onew_i       (1'"'"'b1)/~onew
ps2~s/\.ps2_data_i   (`PAD(10, 1, 1.b1))/.ps2_data_i   (1'"'"'b1)/~ps2
gpio~s/assign gpio_in\[k\] = `PAD(k, 0, 1.b0);/assign gpio_in[k] = `PAD((k ^ 1), 0, 1'"'"'b0);/~gpio'

# 出 .v、编仿真器、跑 xio，回哪几句 BAD（空格隔开）；没跑到 done 的后面跟 stuck 与报了 ok 的那几句（ok:名字）
one() {
  local C=$1 top stuck=
  rm -rf "$C" && mkdir -p "$C"
  (cd "$R" && $RAN asic to2610-soc --no-run -o "$C/asic" > "$C/asic.log" 2>&1) || { echo "出 .v 没成：$(tail -n 2 "$C/asic.log" | tr '\n' ' ')"; return 1; }
  top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$C/asic/report.json")
  python3 htest/shim.py "$C/asic/report.json" > "$C/tb.v"
  bash "$K/htest/sim.sh" "$C/sim" "$C/tb.v" "$C/asic/$top.v" > "$C/sim.log" 2>&1 || { echo "仿真器没编成"; return 1; }
  "$C/sim/Vtb" +flash="$O/xio/xio.bin@0x100000" +script="$O/script" +max=20000000 > "$C/xio.log" 2> "$C/xio.err" || stuck=1
  tr -d '\r' < "$C/xio.log" | awk '$2 == "BAD" {printf "%s ", $1}'
  [ -z "$stuck" ] || { printf 'stuck '; tr -d '\r' < "$C/xio.log" | awk '$2 == "ok" {printf "ok:%s ", $1}'; }
}

got=$(one "$O/clean")
rc=$?
if [ $rc -ne 0 ] || [ -n "$got" ]; then
  echo "原样没过：$got"
  exit 1
fi
n=$(tr -d '\r' < "$O/clean/xio.log" | grep -ac ' ok ')
echo "原样：$n 句都是 ok"

bad=0
count=0
while IFS='~' read -r name expr want; do
  case ",${PINS:-$name}," in *",$name,"*) ;; *) continue ;; esac
  count=$((count + 1))
  sed -e "$expr" hwsrc/soc_frame.v > "$R/hwsrc/soc_frame.v"
  if cmp -s hwsrc/soc_frame.v "$R/hwsrc/soc_frame.v"; then
    echo "$name 没埋上"
    bad=1
    continue
  fi
  got=$(one "$O/mut-$name")
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "$name：$got"
    bad=1
  elif grep -qw -- "$want" <<< "${got%%stuck*}"; then
    echo "$name 红了：${got%%stuck*}"
  elif [[ $got == *stuck* ]] && ! grep -qw -- "ok:$want" <<< "$got"; then
    echo "$name 红了：跑到一半卡住，$want 那一句没报 ok（之前报了 ok 的：$(grep -o 'ok:[a-z0-9]*' <<< "$got" | tail -n 1)）"
  else
    echo "$name 接错了，$want 那一句没红（红的是：${got:-没有}）"
    bad=1
  fi
done <<< "$FAULTS"
cp hwsrc/soc_frame.v "$R/hwsrc/soc_frame.v"
[ $bad -eq 0 ] || { echo "有接错的脚没被抓到"; exit 1; }
echo "引脚的变异：原样过，$count 处接错都红在该红的那一句上"
