#!/usr/bin/env bash
# 数字式 ADC 与 DAC 的单元测试：hwsrc/sdm.v 原样跑一遍要过；再逐个埋错（八处），每个都要红。
# 用法：sdm.sh <输出目录> <to2610-kvc 仓>
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
L=$(realpath "$2")
rm -rf "$O"
mkdir -p "$O"

# 名字、要改掉的那一句（sed 的表达式）、它对应的规矩
muts=(
  "carry~s/bit_q <= sum\[16\];/bit_q <= sum[15];/~DAC 出的是累加器的进位"
  "chan~s/wire \[15:0\] val = k == 0 ? val0 : val1;/wire [15:0] val = val0;/~两路 DAC 各用各的设定值"
  "pre~s/else div <= tick ? pre : div - 8'd1;/else div <= 8'd0;/~PRE 管节拍的宽度"
  "fb~s/fb_q <= !in_s\[1\];/fb_q <= in_s[1];/~反馈与输入脚读到的相反"
  "win~s/ones <= last ? 17'd0 : ones + {16'd0, in_s\[1\]};/ones <= ones + {16'd0, in_s[1]};/~每个窗口从零数起"
  "last~s/held    <= ones + {16'd0, in_s\[1\]};/held    <= ones;/~窗口的最后一拍也算进去"
  "fresh~s/if (rd \&\& sel == 3'd4 + k) fresh_q <= 1'b0;//~有新结果的那一位读一次清掉"
  "clamp~s/3'd6: win <= .*/3'd6: win <= pwdata[4:0];/~WIN 限在 4 到 16"
)

one() {
  local name=$1 expr=$2 d="$O/$1"
  mkdir -p "$d"
  sed "$expr" hwsrc/sdm.v > "$d/sdm.v"
  if [ -n "$expr" ] && cmp -s hwsrc/sdm.v "$d/sdm.v"; then
    echo "$name：这一句没改上" > "$d/run.log"
    return 2
  fi
  verilator --binary --timing -Wno-fatal -Wno-lint --top-module tb -Mdir "$d/obj" -o sim \
    htest/sdm/tb.sv "$d/sdm.v" > "$d/build.log" 2>&1 || { tail -n 5 "$d/build.log"; return 3; }
  "$d/obj/sim" > "$d/run.log" 2>&1 || true
  grep -q '^sdm ok' "$d/run.log"
}

res=()
t0=$SECONDS
rc=0
one clean "" || rc=$?
grep -m3 '^sdm\|^FAIL' "$O/clean/run.log" || true
res+=("clean=$rc:$((SECONDS - t0)):原样：寄存器、DAC 一的个数、ADC 的满与零与三个直流电平、ADC 量 DAC 的闭环")
for m in "${muts[@]}"; do
  IFS='~' read -r name expr what <<< "$m"
  t0=$SECONDS
  rc=0
  one "$name" "$expr" || rc=$?
  case $rc in
    1) v=0; echo "$name 红了：$(grep -m1 FAIL "$O/$name/run.log")" ;;
    0) v=1; echo "$name 埋了错还是过，测试没量到「$what」" ;;
    *) v=1; echo "$name 没跑成（$rc）：$(tail -n 1 "$O/$name/run.log" 2>/dev/null)" ;;
  esac
  res+=("$name=$v:$((SECONDS - t0)):埋错「$what」之后测试要红")
done

python3 "$L/htest/junit.py" "$O/results.xml" "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "sdm 单元测试 ${#res[@]} 项全过"
