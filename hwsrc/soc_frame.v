// Frame 形态的引脚：66 位 payload 里 KianV 的 54 根原位不动（与 to2610-kvc 逐位相同，两颗用同一块底板），
// 余下 12 根（下面叫 x0 至 x11）每根四选一，由 sysctl 的 PADSEL 逐根选，复位后全是 GPIO：
//
//         0（复位）   1              2              3
//   x0    gpio1[0]    uart1 TXD      RMII TXD0      spi2 SCK
//   x1    gpio1[1]    uart1 RXD      RMII TXD1      spi2 CS0_N
//   x2    gpio1[2]    uart1 RTS_N    RMII TX_EN     spi2 MOSI
//   x3    gpio1[3]    uart1 CTS_N    RMII RXD0      spi2 MISO
//   x4    gpio1[4]    I2C SCL        RMII RXD1      SerDes TX
//   x5    gpio1[5]    I2C SDA        RMII CRS_DV    SerDes RX
//   x6    gpio1[6]    单总线         RMII RX_ER     spi2 CS1_N
//   x7    gpio1[7]    CAN TX         PWM 0          I2S SCK
//   x8    gpio1[8]    CAN RX         PWM 1          I2S WS
//   x9    gpio1[9]    PS/2 时钟      PWM 2          I2S SD 出
//   x10   gpio1[10]   PS/2 数据      PWM 3          I2S SD 入
//   x11   gpio1[11]   计时器捕获 0   看门狗复位出   随机源入
//
// 没选到焊盘上的输入给空闲电平：串口、I2C、单总线、CAN、PS/2 是高，其余是低。
// 这个形态里没有 PLL，SerDes 的线路时钟就是系统时钟，线速率 12.5 Mbit/s。
// 数字式 ADC 与 DAC 不另占功能组：sdm 的 PINS 位一开，x6 至 x11 在第 0 组里出的就是它的六根脚。
`default_nettype none
module soc_frame (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [53:0] bidir_in,
    output wire [53:0] bidir_out,
    output wire [53:0] bidir_oe,
    input  wire [11:0] x_in,
    output wire [11:0] x_out,
    output wire [11:0] x_oe
);
  wire        txd, rts_n, wdt_rst_out, scl_pull, sda_pull, sck, ow_pull;
  wire        i2s_sck, i2s_ws, i2s_sd_o, can_tx, ps2_clk_pull, ps2_data_pull, tx_en, sd_tx;
  wire [15:0] gpio_out, gpio_dir;
  wire [ 1:0] cs_n, rmii_txd;
  wire [ 1:0] io_o, io_oe;
  wire [ 3:0] pwm;
  wire [23:0] padsel;

  // 四个功能各自的出与出使能，每个 12 位，高位是 x11。开漏的脚出 0、由「拉低」当出使能
  wire [11:0] out0 = gpio_out[11:0];
  wire [11:0] oe0 = gpio_dir[11:0];
  //                  x11   x10            x9            x8    x7      x6       x5        x4        x3    x2     x1    x0
  wire [11:0] out1 = {1'b0, 1'b0, 1'b0, 1'b0, can_tx, 1'b0, 1'b0, 1'b0, 1'b0, rts_n, 1'b0, txd};
  wire [11:0] oe1 = {1'b0, ps2_data_pull, ps2_clk_pull, 1'b0, 1'b1, ow_pull, sda_pull, scl_pull, 1'b0, 1'b1, 1'b0, 1'b1};
  wire [11:0] out2 = {wdt_rst_out, pwm[3:0], 4'b0000, tx_en, rmii_txd[1:0]};
  wire [11:0] oe2 = {5'b11111, 4'b0000, 3'b111};
  wire [11:0] out3 = {1'b0, 1'b0, i2s_sd_o, i2s_ws, i2s_sck, cs_n[1], 1'b0, sd_tx, io_o[1:0], cs_n[0], sck};
  wire [11:0] oe3 = {1'b0, 1'b0, 3'b111, 1'b1, 2'b01, io_oe[1:0], 2'b11};

  genvar k;
  generate
    for (k = 0; k < 12; k = k + 1) begin : mux
      wire [1:0] s = padsel[2*k+:2];
      assign x_out[k] = s == 2'd0 ? out0[k] : s == 2'd1 ? out1[k] : s == 2'd2 ? out2[k] : out3[k];
      assign x_oe[k]  = s == 2'd0 ? oe0[k] : s == 2'd1 ? oe1[k] : s == 2'd2 ? oe2[k] : oe3[k];
    end
  endgenerate

  // 选到了才取焊盘上的电平，没选到给空闲电平
  `define PAD(k, f, idle) (padsel[2*(k)+:2] == (f) ? x_in[k] : idle)
  wire [11:0] gpio_in;
  generate
    for (k = 0; k < 12; k = k + 1) begin : gin
      assign gpio_in[k] = `PAD(k, 0, 1'b0);
    end
  endgenerate

  soc_core #(
      .MPW(0)
  ) core (
      .clk          (clk),
      .rst_n        (rst_n),
      .bidir_in     (bidir_in),
      .bidir_out    (bidir_out),
      .bidir_oe     (bidir_oe),
      .uart1_txd    (txd),
      .uart1_rxd    (`PAD(1, 1, 1'b1)),
      .uart1_rts_n  (rts_n),
      .uart1_cts_n  (`PAD(3, 1, 1'b1)),
      .gpio1_in     ({4'h0, gpio_in}),
      .gpio1_out    (gpio_out),
      .gpio1_dir    (gpio_dir),
      .timer_capt   ({1'b0, `PAD(11, 1, 1'b0)}),
      .wdt_rst_out  (wdt_rst_out),
      .i2c_scl_pull (scl_pull),
      .i2c_sda_pull (sda_pull),
      .i2c_scl_i    (`PAD(4, 1, 1'b1)),
      .i2c_sda_i    (`PAD(5, 1, 1'b1)),
      .spi2_sck     (sck),
      .spi2_cs_n    (cs_n),
      .spi2_io_o    (io_o),
      .spi2_io_oe   (io_oe),
      .spi2_io_i    ({`PAD(3, 3, 1'b0), `PAD(2, 3, 1'b0)}),
      .onew_pull    (ow_pull),
      .onew_i       (`PAD(6, 1, 1'b1)),
      .i2s_sck      (i2s_sck),
      .i2s_ws       (i2s_ws),
      .i2s_sd_o     (i2s_sd_o),
      .i2s_sd_i     (`PAD(10, 3, 1'b0)),
      .can_tx       (can_tx),
      .can_rx       (`PAD(8, 1, 1'b1)),
      .ps2_clk_pull (ps2_clk_pull),
      .ps2_data_pull(ps2_data_pull),
      .ps2_clk_i    (`PAD(9, 1, 1'b1)),
      .ps2_data_i   (`PAD(10, 1, 1'b1)),
      .rng_noise    (`PAD(11, 3, 1'b0)),
      .rmii_txd     (rmii_txd),
      .rmii_tx_en   (tx_en),
      .rmii_rxd     ({`PAD(4, 2, 1'b0), `PAD(3, 2, 1'b0)}),
      .rmii_crs_dv  (`PAD(5, 2, 1'b0)),
      .rmii_rx_er   (`PAD(6, 2, 1'b0)),
      .pwm          (pwm),
      .pwm_n        (),
      .sd_tx        (sd_tx),
      .sd_rx        (`PAD(5, 3, 1'b0)),
      .pll_en       (),
      .pll_bp       (),
      .pll_n        (),
      .pll_select   (),
      .pll_od       (),
      .pll_refclk   (),
      .pll_ckout    (1'b0),
      .clk_out      (),
      .padsel       (padsel)
  );
  `undef PAD
endmodule
`default_nettype wire
