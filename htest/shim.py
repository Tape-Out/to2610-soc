"""照 report.json 的位表写测试台要的 tb。

KianV 的 54 根脚照 to2610-kvc 的样子交给黑盒仓的测试台（它带 SDRAM、Flash、串口的模型）；
复用的 12 根脚不出这个模块，在这里就地接成回环或最小的片外模型，裸机测试靠它们判对错。
12 根脚选的是哪一组功能，测试台从出使能的样子上认（四组各不相同，排法见 hwsrc/soc_frame.v）：

  GPIO      第 k 根与第 k+4 根对接（k 取 0 至 3）。sdm 接管了 x6 至 x11 时（出使能是 010111、低六根都不出）
            换成数字式 ADC 在板上的那一半：第 0 路量四分之一满幅的直流，第 1 路量第 0 路 DAC 的码流
  第 1 组   串口 1 的 TXD 接回 RXD、RTS_N 接回 CTS_N；单总线上一个只会应答复位的器件；
            PS/2 上一个每 3 毫秒送一次 0x1C 的设备；CAN 的 TX 接回 RX
  第 2 组   RMII 的发送接回接收（TXD 到 RXD，TX_EN 到 CRS_DV）
  第 3 组   SPI 上一个回声从设备（每个字节回上一个字节的反码，头一个回 0xFF，片选一抬就忘）；I2S 的 SD 出接回入；
            SerDes 的 TX 接回 RX

没人驱动的脚都由板上的上拉拉高。位表只写在 report.json 里一处，这里照着它生成，不另写一份。
"""
import json
import re
import sys

rep = json.load(open(sys.argv[1], encoding="utf-8"))
W = rep["pads"]["width"]
ins, outs = {}, []
for b in rep["pads"]["bits"]:
    for role in ("in", "out", "oe"):
        if not b[role]:
            continue
        m = re.fullmatch(rf"(bidir|x)_{role}\[(\d+)\]", b[role])
        assert m, b[role]
        sig = ("pad" if m[1] == "bidir" else "x") + f"_{role}[{m[2]}]"
        if role == "in":
            ins[b["bit"]] = sig
        else:
            outs.append(f"  assign {sig} = io_{role}[{b['bit']}];")
io_in = ", ".join(ins.get(i, "1'b0") for i in range(W - 1, -1, -1))
print(f"""// 由 htest/shim.py 照 report.json 生成
module tb (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [53:0] pad_in,
  output wire [53:0] pad_out,
  output wire [53:0] pad_oe
);
  wire [11:0] x_in, x_out, x_oe;
  wire [{W - 1}:0] io_out, io_oe;
  wire [{W - 1}:0] io_in = {{{io_in}}};
{chr(10).join(outs)}
  {rep["top"]} chip (.clock(clk), .reset(~rst_n), .io_in(io_in), .io_out(io_out), .io_oe(io_oe));
""" + r"""
  // 芯片在这根脚上给出的电平：不驱动时是上拉
  wire [11:0] lv = (x_out & x_oe) | ~x_oe;

  wire m1 = x_oe[3:0] == 4'b0101 && x_oe[8:7] == 2'b01;
  wire m2 = x_oe[2:0] == 3'b111 && x_oe[6:3] == 4'b0000 && x_oe[11:7] == 5'b11111;
  wire m3 = x_oe[1:0] == 2'b11 && x_oe[9:6] == 4'b1111 && x_oe[11:10] == 2'b00;

  // 单总线器件：线被拉低满 400 微秒后松开，过 30 微秒它拉低 120 微秒（50 MHz 下一微秒 50 拍）
  reg [15:0] ow_low, ow_t;
  wire       ow_pulled = m1 && !lv[6];
  wire       ow_dev = ow_t >= 16'd1500 && ow_t < 16'd7500;
  always @(posedge clk) begin
    if (!rst_n) begin
      ow_low <= 16'd0;
      ow_t   <= 16'd0;
    end else if (ow_pulled) begin
      ow_low <= ow_low == 16'hffff ? ow_low : ow_low + 16'd1;
      ow_t   <= 16'd0;
    end else begin
      ow_low <= 16'd0;
      if (ow_low >= 16'd20000) ow_t <= 16'd1;
      else if (ow_t != 16'd0) ow_t <= ow_t == 16'd7500 ? 16'd0 : ow_t + 16'd1;
    end
  end

  // PS/2 设备：每 3 毫秒送一帧 0x1C。一位 80 微秒，时钟先高后低各一半，数据在时钟高的时候换
  localparam [10:0] PS2_FRAME = {1'b1, 1'b0, 8'h1c, 1'b0};
  reg  [17:0] ps2_t;
  wire [17:0] ps2_at = ps2_t - 18'd50000;
  wire        ps2_on = m1 && ps2_t >= 18'd50000 && ps2_t < 18'd94000;
  wire        ps2_clk = !ps2_on || ps2_at % 18'd4000 < 18'd2000;
  wire        ps2_dat = !ps2_on || PS2_FRAME[ps2_at / 18'd4000];
  always @(posedge clk) ps2_t <= !rst_n || !m1 || ps2_t == 18'd149999 ? 18'd0 : ps2_t + 18'd1;

  // SPI 回声从设备，模式 0：上升沿采 MOSI，下降沿换 MISO
  reg [7:0] sp_sh, sp_out;
  reg [2:0] sp_n;
  reg       sp_sck, miso;
  always @(posedge clk) begin
    sp_sck <= lv[0];
    if (!m3 || lv[1]) begin
      sp_n   <= 3'd0;
      sp_out <= 8'hff;
      miso   <= 1'b1;
    end else begin
      if (lv[0] && !sp_sck) begin
        sp_sh <= {sp_sh[6:0], lv[2]};
        sp_n  <= sp_n + 3'd1;
        if (sp_n == 3'd7) sp_out <= ~{sp_sh[6:0], lv[2]};
      end
      if (!lv[0] && sp_sck) miso <= sp_out[3'd7 - sp_n];
    end
  end

  // 数字式 ADC 在板上的那一半：被测电压与反馈脚各经一颗电阻汇到一颗电容上，这里拿一个封顶的累加器当电容，
  // 每拍加上两边各自相对门限的差，大于零输入脚读到 1
  wire ma = !m1 && !m2 && !m3 && x_oe[11:6] == 6'b010111 && x_oe[5:0] == 6'b000000;
  localparam signed [23:0] FULL = 24'sd65536, SAT = 24'sd524288;
  reg  signed [23:0] n0, n1;
  wire signed [23:0] d0 = n0 + 24'sd16384 + (lv[8] ? FULL : 24'sd0) - FULL;
  wire signed [23:0] d1 = n1 + (lv[6] ? FULL : 24'sd0) + (lv[10] ? FULL : 24'sd0) - FULL;
  always @(posedge clk) begin
    if (!rst_n || !ma) begin
      n0 <= 24'sd0;
      n1 <= 24'sd0;
    end else begin
      n0 <= d0 > SAT ? SAT : d0 < -SAT ? -SAT : d0;
      n1 <= d1 > SAT ? SAT : d1 < -SAT ? -SAT : d1;
    end
  end

  // 板子在每根脚上给的电平，芯片自己驱动时以芯片的为准
  reg [11:0] drv;
  always @* begin
    drv = 12'hfff;
    if (m1) begin
      drv[1]  = lv[0];
      drv[3]  = lv[2];
      drv[6]  = !ow_dev;
      drv[8]  = lv[7];
      drv[9]  = ps2_clk;
      drv[10] = ps2_dat;
    end else if (m2) begin
      drv[3] = lv[0];
      drv[4] = lv[1];
      drv[5] = lv[2];
      drv[6] = 1'b0;
    end else if (m3) begin
      drv[3]  = miso;
      drv[5]  = lv[4];
      drv[10] = lv[9];
    end else if (ma) begin
      drv[9]  = n0 > 24'sd0;
      drv[11] = n1 > 24'sd0;
    end else begin
      drv[3:0] = lv[7:4];
      drv[7:4] = lv[3:0];
    end
  end
  assign x_in = (x_out & x_oe) | (drv & ~x_oe);
endmodule
""")
