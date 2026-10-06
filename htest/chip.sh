#!/usr/bin/env bash
# 整片测试，全部跑在 ran asic 出的那份 .v 上。测试台、片外模型来自黑盒仓，引导程序与拼镜像的脚本来自 to2610-kvc。
#   hello  to2610-kvc 的裸机冒烟原样跑一遍：开了地址窗之后原有的东西不许变
#   periph to2610-kvc 的外设测试原样跑一遍：GPIO、两路 SPI、计时器中断、PLIC、重启
#   isa    标准 riscv-tests 逐个跑，同 to2610-kvc：核的行为不许变
#   boot   引导程序带回显载荷，同上
#   xio    窗后面的外设逐个点一遍，测试台上是回环与最小的片外模型（htest/shim.py）
#   rtos、image  to2610-kvc 的 FreeRTOS 冒烟原样在这一颗上跑；它的 Linux 镜像先过 QEMU
#   linux  同一份镜像在这一颗上从 Flash 起到 shell。仿真要五六个小时，带 SOC_LINUX=1 才跑
# 用法：chip.sh <输出目录> <gf180mcu-kianv-rv32ima-sv32 仓> <to2610-kvc 仓>。已经跑过 ran asic 的，把输出目录给 CHIP_ASIC
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
L=$(realpath "$3")
rm -rf "$O"
mkdir -p "$O"
A=${CHIP_ASIC:-$O/asic}
[ -s "$A/report.json" ] || $XIRANG asic to2610-soc --no-run -o "$A"
top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$A/report.json")
python3 htest/shim.py "$A/report.json" > "$O/tb.v"
bash "$K/htest/sim.sh" "$O/sim" "$O/tb.v" "$A/$top.v"

res=()
run() {
  local name=$1 what=$2 t0=$SECONDS rc=0
  shift 2
  "$O/sim/Vtb" "$@" > "$O/$name.log" 2> "$O/$name.err" || rc=$?
  tail -n 3 "$O/$name.err"
  res+=("$name=$rc:$((SECONDS - t0)):$what")
}

make -s -C "$K/htest/hello" O="$O/hello"
run hello "to2610-kvc 的裸机冒烟：从 Flash 就地执行，读写 SDRAM" \
  +flash="$O/hello/hello.bin@0x100000" +script="$K/htest/hello/script" +max=30000000

make -s -C "$K/htest/periph" O="$O/periph"
run periph "to2610-kvc 的外设测试：GPIO、两路 SPI 与回声从设备、计时器中断、PLIC、重启" \
  +flash="$O/periph/periph.bin@0x100000" +script="$K/htest/periph/script" +spiecho +max=30000000

t0=$SECONDS
rc=0
SIM="$O/sim" bash "$K/htest/isa.sh" "$O/isa" > "$O/isa.log" 2>&1 || rc=$?
tail -n 3 "$O/isa.log"
res+=("isa=$rc:$((SECONDS - t0)):riscv-tests 的 rv32ui、um、ua、mi、si 逐个在这份 .v 上跑，程序放进 SDRAM、测试台盯 tohost；已知失败钉住，多过一个少过一个都算红")

make -s -C "$L/sw/boot" O="$O/boot"
make -s -C "$L/htest/echo" O="$O/echo"
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/echo/echo.bin" "$O/echo.flash"
run boot "引导程序搬载荷并核对校验和，载荷回显串口" \
  +flash="$O/echo.flash@0" +script="$L/htest/echo/script" +max=60000000

# 寄存器偏移不手抄：让息壤照各 IP 的 regmap.yaml 出头文件
mkdir -p "$O/xio/inc"
for ip in uart gpio timer wdt rtc i2c spi onew i2s can ps2 rng emac pwm crc; do
  $XIRANG gen "$ip" -o "$O/xio/gen/$ip" > /dev/null
  cp "$O/xio/gen/$ip/sw/$ip.h" "$O/xio/inc/"
done
make -s -C htest/xio O="$O/xio" HELLO="$K/htest/hello"
run xio "窗后面的十五个外设：每个实例的地址各应各的；GPIO、串口、单总线、PS/2、以太网、SPI、I2S 经复用焊盘与板上的回环或片外模型走通；串口、GPIO、计时器三路中断经 PLIC 的 11、12、13 号进来；CRC 算出目录里的校验值" \
  +flash="$O/xio/xio.bin@0x100000" +script=htest/xio/script +max=60000000

make -s -C "$L/htest/rtos" O="$O/rtos"
python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$O/rtos/rtos.bin" "$O/rtos.flash"
run rtos "to2610-kvc 的 FreeRTOS 冒烟：三个任务、队列、互斥量、节拍与抢占" \
  +flash="$O/rtos.flash@0" +script="$L/htest/rtos/script" +max=20000000

# Linux 镜像就是 to2610-kvc 的那一份：它在本机编过就用编出来的，不然照它的 image.pin 去发布页取
I=${LINUX_IMAGE:-$L/build/linux/fw_payload.bin}
if [ ! -s "$I" ] && [ -s "$L/sw/linux/image.pin" ]; then
  I=$O/fw_payload.bin
  read -r url sum < "$L/sw/linux/image.pin"
  if curl -fsSL --retry 5 -o "$I.part" "$url" && echo "$sum  $I.part" | sha256sum -c - > /dev/null; then
    mv "$I.part" "$I"
  else
    rm -f "$I.part"
    echo "取不到镜像 $url，或摘要不是 $sum"
  fi
fi
if [ -s "$I" ]; then
  t0=$SECONDS
  rc=0
  python3 "$L/htest/qemu.py" "$I" "$L/htest/image.script" "$O/qemu" > "$O/image.log" 2>&1 || rc=$?
  tail -n 3 "$O/image.log"
  res+=("image=$rc:$((SECONDS - t0)):载荷里的内核带着根文件系统在 QEMU 的 virt 机器上起到 shell；只验软件，拦坏镜像")
  if [ $rc != 0 ]; then
    res+=("linux=1:0:镜像没过 QEMU 那一关，没跑")
  elif [ "${SOC_LINUX:-}" != 1 ]; then
    # 这一颗的仿真每秒不到三十万拍（emac 的帧缓冲区是几百个寄存器加几路大选择器），Linux 起一遍要五六个小时，
    # 托管机的一个作业撑不到。要跑就带上 SOC_LINUX=1；没跑就不记这一段，不算过
    echo "linux 这一段没跑（要 SOC_LINUX=1）"
  else
    python3 "$L/sw/pack.py" "$O/boot/boot.bin" "$I" "$O/linux.flash"
    # 发字节的间隔 60 万拍：见 to2610-kvc 的 chip.sh
    run linux "to2610-kvc 的镜像原样在这一颗上从 Flash 起到 shell，跑它的那组命令：开了地址窗、接了外设之后 Linux 照常起来" \
      +flash="$O/linux.flash@0" +script="$L/htest/linux.script" +pace=600000 +max="${LINUX_MAX:-8000000000}" +beat=1000000000
  fi
else
  echo "没有 Linux 镜像 $I"
  res+=("image=1:0:没有镜像，没跑" "linux=1:0:没有镜像，没跑")
fi

python3 "$L/htest/junit.py" "$O/results.xml" "${res[@]}"
printf '%s\n' "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "整片测试 ${#res[@]} 段全过"
