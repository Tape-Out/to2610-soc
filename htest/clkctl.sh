#!/usr/bin/env bash
# 时钟控制的测试：hwsrc/clkctl.v 配上 PLL 的行为模型与 serdes 的通道，两颗对接。原样跑一遍要过；再逐个埋错（九处），每个都要红。
# 用法：clkctl.sh <输出目录> <serdes 仓> <to2610-kvc 仓>
# PLL 的模型默认用 htest/clkctl/pll_model.v；设 PLL_MODEL=<文件> 换成别的（比如 ECOS 的 PLL_TOP.behavioral.v），只跑原样那一遍
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
D=$(realpath "$2")
L=$(realpath "$3")
rm -rf "$O"
mkdir -p "$O"
MODEL=${PLL_MODEL:-htest/clkctl/pll_model.v}

# 名字、要改掉的那一句（sed 的表达式）、它对应的规矩
muts=(
  "div~s/if (cnt >= d2) begin/if (cnt > d2) begin/~分出来的是 PLL 的输出除以 2 ×（D + 1）"
  "ref~s/else ref_q <= !ref_q;/else ref_q <= clk;/~参考时钟是系统时钟的二分频"
  "bp~s/assign pll_bp     = bp;/assign pll_bp     = 1'b0;/~BP 接到宏上"
  "od~s/assign pll_od     = od;/assign pll_od     = 2'd3;/~OD 接到宏上"
  "select~s/assign pll_select = select;/assign pll_select = 1'b0;/~SELECT 接到宏上"
  "src~s/b_s <= {b_s\[0\], src \&\& !a_s\[1\]};/b_s <= {b_s[0], 1'b0};/~SRC 把线路时钟换到分出来的那一路"
  "out~s/assign clk_out = q \& out;/assign clk_out = q;/~OUT 关着时 clk_out 不动"
  "delta~s/freq_q  <= bin - last;/freq_q  <= bin;/~FREQ 是一个窗口里的周期数"
  "fresh~s/if (rd \&\& sel == 2'd3) fresh_q <= 1'b0;//~有新结果的那一位读一次清掉"
)

one() {
  local name=$1 expr=$2 d="$O/$1"
  mkdir -p "$d"
  sed "$expr" hwsrc/clkctl.v > "$d/clkctl.v"
  if [ -n "$expr" ] && cmp -s hwsrc/clkctl.v "$d/clkctl.v"; then
    echo "$name：这一句没改上" > "$d/run.log"
    return 2
  fi
  iverilog -g2012 -Wno-timescale -o "$d/tb.vvp" -s tb htest/clkctl/tb.v "$MODEL" "$d/clkctl.v" "$D"/hwsrc/serdes_*.v \
    > "$d/build.log" 2>&1 || { tail -n 5 "$d/build.log"; return 3; }
  vvp -n "$d/tb.vvp" > "$d/run.log" 2>&1 || true
  grep -q '^PASS tb_clk$' "$d/run.log"
}

res=()
t0=$SECONDS
rc=0
one clean "" || rc=$?
grep -m4 '^PASS\|^FAIL' "$O/clean/run.log" || true
res+=("clean=$rc:$((SECONDS - t0)):原样：复位值、旁路、五组倍频与分频、不合法的组合、clk_out、PLL 的时钟下 SerDes 自环与两颗对接、两档速率、速率不同锁不上、切回系统时钟")
if [ -z "${PLL_MODEL:-}" ]; then
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
fi

python3 "$L/htest/junit.py" "$O/results.xml" "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "时钟控制的测试 ${#res[@]} 项全过"
