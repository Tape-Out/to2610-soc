// PLL_TOP 的行为模型，只在仿真里用，照 ECOS 公开的接口说明写：
//   VCO = 参考 × N ×（SELECT ? 2 : 1），输出是 VCO 除以 OD 那一档（1、2、4、8）；BP 为 1 时输出就是参考时钟。
//   参考不在 5 至 40 MHz、N 不大于 16、VCO 不在 500 至 1200 MHz 时不出时钟。EN 之后 15 微秒起振。
//   设置不合法（开的时候不合法，或者跑着的时候改成了不合法的）就停住，要把 EN 放下再拉起才重来，与 ECOS 的模型一样。
// ECOS 自己的行为模型（ics55_ecos_pll 仓）许可未定，不放进这个仓；测试台换上它跑，读数与用这一份时相同。
`timescale 1ns / 1ps
module PLL_TOP (
    input  wire       EN,
    input  wire       BP,
    input  wire [7:0] N,
    input  wire       SELECT,
    input  wire [1:0] OD,
    input  wire       REFCLK,
    inout  wire       AVDD,
    inout  wire       AVSS,
    inout  wire       DVDD,
    inout  wire       DVSS,
    inout  wire       DVDD_DRV,
    inout  wire       DVSS_DRV,
    output wire       CKOUT1,
    output wire       CKOUT2,
    output wire       CKTST
);
  realtime last = 0, period = 0;
  always @(posedge REFCLK) begin
    period = $realtime - last;
    last   = $realtime;
  end

  real fref, fvco;
  reg  ok;
  always @(*) begin
    fref = period > 0 ? 1000.0 / period : 0.0;
    fvco = fref * N * (SELECT ? 2.0 : 1.0);
    ok   = fref >= 5.0 && fref <= 40.0 && N > 8'd16 && fvco >= 500.0 && fvco <= 1200.0;
  end

  reg out = 1'b0, tst = 1'b0;
  reg run = 1'b0;
  always begin
    run = 1'b0;
    wait (EN === 1'b1);
    #15000;
    run = EN === 1'b1 && ok;
    while (run) @(EN or ok) run = EN === 1'b1 && ok;
    wait (EN !== 1'b1);
  end
  always begin
    out = 1'b0;
    wait (run);
    while (run) #(500.0 * (1 << OD) / fvco) out = !out;
  end
  always begin
    tst = 1'b0;
    wait (run);
    while (run) #(500.0 * 64.0 / fvco) tst = !tst;
  end

  assign CKOUT1 = BP ? REFCLK : out;
  assign CKOUT2 = BP ? REFCLK : out;
  assign CKTST  = tst;
endmodule
