// to2610-soc 两个形态共用的核心：KianV 那颗 SoC（chip_core，带 patch/soc.patch 开的地址窗）加窗后面的外设。
// 窗在 0x4000_0000，按 addr[27:16] 分块：
//   0x000  息壤装配的 soc-io，里面每个实例一页；0xC000、0xD000 两页是以太网 soc-eth，只有 MPW 形态例化
//   0x001  serdes_apb：一条 SerDes 通道（Tape-Out/serdes），线路时钟另给，中断接 PLIC 的 27 号
//   0x002  sdm：两路数字式 DAC、两路数字式 ADC，它的六根脚可以接管 GPIO 1 的第 6 至 11 位
//   0x003  sysctl：标识与 Frame 形态的引脚复用
//   0x005  clkctl：PLL 的倍频与分频、SerDes 的线路时钟取哪一路、测频。MPW 为 0 时片上没有 PLL，寄存器照样在
// 没有东西的块读回 0、写了不管。外设的中断按 soc-io 里实例的次序接到 PLIC 的 11 号起。
// 开漏的脚（I2C、单总线、PS/2）出的是「拉低」一根线，电平靠板上的上拉。
`default_nettype none
module soc_core #(
    parameter MPW = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [53:0] bidir_in,
    output wire [53:0] bidir_out,
    output wire [53:0] bidir_oe,

    output wire        uart1_txd,
    input  wire        uart1_rxd,
    output wire        uart1_rts_n,
    input  wire        uart1_cts_n,
    input  wire [15:0] gpio1_in,
    output wire [15:0] gpio1_out,
    output wire [15:0] gpio1_dir,
    input  wire [ 1:0] timer_capt,
    output wire        wdt_rst_out,
    output wire        i2c_scl_pull,
    output wire        i2c_sda_pull,
    input  wire        i2c_scl_i,
    input  wire        i2c_sda_i,
    output wire        spi2_sck,
    output wire [ 1:0] spi2_cs_n,
    output wire [ 1:0] spi2_io_o,
    output wire [ 1:0] spi2_io_oe,
    input  wire [ 1:0] spi2_io_i,
    output wire        onew_pull,
    input  wire        onew_i,
    output wire        i2s_sck,
    output wire        i2s_ws,
    output wire        i2s_sd_o,
    input  wire        i2s_sd_i,
    output wire        can_tx,
    input  wire        can_rx,
    output wire        ps2_clk_pull,
    output wire        ps2_data_pull,
    input  wire        ps2_clk_i,
    input  wire        ps2_data_i,
    input  wire        rng_noise,
    output wire [ 1:0] rmii_txd,
    output wire        rmii_tx_en,
    input  wire [ 1:0] rmii_rxd,
    input  wire        rmii_crs_dv,
    input  wire        rmii_rx_er,
    output wire [ 3:0] pwm,
    output wire [ 3:0] pwm_n,

    output wire        sd_tx,
    input  wire        sd_rx,
    output wire        pll_en,
    output wire        pll_bp,
    output wire [ 7:0] pll_n,
    output wire        pll_select,
    output wire [ 1:0] pll_od,
    output wire        pll_refclk,
    input  wire        pll_ckout,
    output wire        clk_out,

    output wire [23:0] padsel
);
  wire        xio_resetn, xio_valid, xio_ready;
  wire [31:0] xio_addr, xio_wdata, xio_rdata;
  wire [ 3:0] xio_wstrb;
  wire [20:0] xio_irq;

  chip_core core (
      .clk       (clk),
      .rst_n     (rst_n),
      .bidir_in  (bidir_in),
      .bidir_out (bidir_out),
      .bidir_oe  (bidir_oe),
      .bidir_cs  (),
      .bidir_sl  (),
      .bidir_ie  (),
      .bidir_pu  (),
      .bidir_pd  (),
      .xio_resetn(xio_resetn),
      .xio_valid (xio_valid),
      .xio_addr  (xio_addr),
      .xio_wstrb (xio_wstrb),
      .xio_wdata (xio_wdata),
      .xio_rdata (xio_rdata),
      .xio_ready (xio_ready),
      .xio_irq   (xio_irq)
  );

  wire        psel, penable, pwrite, pready, pslverr;
  wire [27:0] paddr;
  wire [31:0] pwdata, prdata;
  wire [ 3:0] pstrb;

  kv_apb bridge (
      .clk        (clk),
      .resetn     (xio_resetn),
      .bus_valid_i(xio_valid),
      .bus_addr_i (xio_addr),
      .bus_wstrb_i(xio_wstrb),
      .bus_wdata_i(xio_wdata),
      .bus_rdata_o(xio_rdata),
      .bus_ready_o(xio_ready),
      .psel       (psel),
      .penable    (penable),
      .pwrite     (pwrite),
      .paddr      (paddr),
      .pwdata     (pwdata),
      .pstrb      (pstrb),
      .pready     (pready),
      .prdata     (prdata),
      .pslverr    (pslverr)
  );

  wire        io_sel = paddr[27:16] == 12'h000;
  wire        sd_sel = paddr[27:16] == 12'h001;
  wire        sdm_sel = paddr[27:16] == 12'h002;
  wire        sys_sel = paddr[27:16] == 12'h003;
  wire        clk_sel = paddr[27:16] == 12'h005;
  wire        io_pready, io_pslverr, sd_irq;
  wire [31:0] io_prdata, sd_prdata, sdm_prdata, sys_prdata, clk_prdata;
  wire        sd_lclk;
  wire [15:0] g_out, g_dir;
  wire        ana;
  wire [ 1:0] sdm_dac, sdm_fb;
  wire [13:0] io_irqs;
  wire        eth_sel = io_sel && paddr[15:13] == 3'b110;
  wire        eth_pready, eth_pslverr, eth_irq;
  wire [31:0] eth_prdata;

  to2610_soc_io io (
      .clk                 (clk),
      .rst_n               (xio_resetn),
      .bus_paddr           ({16'h0, paddr[15:0]}),
      .bus_pprot           (3'b000),
      .bus_psel            (psel && io_sel && !eth_sel),
      .bus_penable         (penable),
      .bus_pwrite          (pwrite),
      .bus_pwdata          (pwdata),
      .bus_pstrb           (pstrb),
      .bus_pready          (io_pready),
      .bus_prdata          (io_prdata),
      .bus_pslverr         (io_pslverr),
      .uart1_pins_txd      (uart1_txd),
      .uart1_pins_rxd      (uart1_rxd),
      .uart1_pins_cts_n    (uart1_cts_n),
      .uart1_pins_rts_n    (uart1_rts_n),
      .gpio1_pins_gpio_in  (gpio1_in),
      .gpio1_pins_gpio_out (g_out),
      .gpio1_pins_gpio_dir (g_dir),
      .timer0_pins_capt_in (timer_capt),
      .wdt0_pins_rst_out   (wdt_rst_out),
      .i2c0_pins_scl_pull  (i2c_scl_pull),
      .i2c0_pins_sda_pull  (i2c_sda_pull),
      .i2c0_pins_scl_i     (i2c_scl_i),
      .i2c0_pins_sda_i     (i2c_sda_i),
      .spi2_pins_sck       (spi2_sck),
      .spi2_pins_cs_n      (spi2_cs_n),
      .spi2_pins_io_o      (spi2_io_o),
      .spi2_pins_io_oe     (spi2_io_oe),
      .spi2_pins_io_i      (spi2_io_i),
      .onew0_pins_ow_pull  (onew_pull),
      .onew0_pins_ow_i     (onew_i),
      .i2s0_pins_sck       (i2s_sck),
      .i2s0_pins_ws        (i2s_ws),
      .i2s0_pins_sd_o      (i2s_sd_o),
      .i2s0_pins_sd_i      (i2s_sd_i),
      .can0_pins_can_tx    (can_tx),
      .can0_pins_can_rx    (can_rx),
      .ps2_pins_clk_pull   (ps2_clk_pull),
      .ps2_pins_data_pull  (ps2_data_pull),
      .ps2_pins_clk_i      (ps2_clk_i),
      .ps2_pins_data_i     (ps2_data_i),
      .rng0_pins_noise_i   (rng_noise),
      .pwm0_pins_pwm       (pwm),
      .pwm0_pins_pwm_n     (pwm_n),
      .irqs                (io_irqs)
  );

  // Frame 的 1 mm² 里放不下以太网的帧缓冲区（两次布线都不收敛），只在 MPW 形态里有
  generate
    if (MPW) begin : g_eth
      to2610_soc_eth eth (
          .clk                 (clk),
          .rst_n               (xio_resetn),
          .bus_paddr           ({19'h0, paddr[12:0]}),
          .bus_pprot           (3'b000),
          .bus_psel            (psel && eth_sel),
          .bus_penable         (penable),
          .bus_pwrite          (pwrite),
          .bus_pwdata          (pwdata),
          .bus_pstrb           (pstrb),
          .bus_pready          (eth_pready),
          .bus_prdata          (eth_prdata),
          .bus_pslverr         (eth_pslverr),
          .emac0_pins_tx_txd   (rmii_txd),
          .emac0_pins_tx_tx_en (rmii_tx_en),
          .emac0_pins_rx_rxd   (rmii_rxd),
          .emac0_pins_rx_crs_dv(rmii_crs_dv),
          .emac0_pins_rx_rx_er (rmii_rx_er),
          .irqs                (eth_irq)
      );
    end else begin : g_noeth
      assign rmii_txd    = 2'b00;
      assign rmii_tx_en  = 1'b0;
      assign eth_pready  = 1'b1;
      assign eth_prdata  = 32'h0;
      assign eth_pslverr = 1'b0;
      assign eth_irq     = 1'b0;
    end
  endgenerate

  serdes_apb sd (
      .pclk   (clk),
      .presetn(xio_resetn),
      .psel   (psel && sd_sel),
      .penable(penable),
      .pwrite (pwrite),
      .paddr  (paddr[7:0]),
      .pwdata (pwdata),
      .prdata (sd_prdata),
      .irq    (sd_irq),
      .lclk   (sd_lclk),
      .tx     (sd_tx),
      .rx     (sd_rx)
  );

  sdm sdm (
      .clk    (clk),
      .rst_n  (xio_resetn),
      .psel   (psel && sdm_sel),
      .penable(penable),
      .pwrite (pwrite),
      .paddr  (paddr[7:0]),
      .pwdata (pwdata),
      .prdata (sdm_prdata),
      .pins   (ana),
      .dac    (sdm_dac),
      .adc_fb (sdm_fb),
      .adc_in ({gpio1_in[11], gpio1_in[9]})
  );

  // 接管的六位从低到高：DAC0、DAC1、ADC0 的反馈、ADC0 的输入、ADC1 的反馈、ADC1 的输入
  assign gpio1_out = ana ? {g_out[15:12], 1'b0, sdm_fb[1], 1'b0, sdm_fb[0], sdm_dac, g_out[5:0]} : g_out;
  assign gpio1_dir = ana ? {g_dir[15:12], 6'b010111, g_dir[5:0]} : g_dir;

  clkctl #(
      .PLL(MPW)
  ) clkc (
      .clk       (clk),
      .rst_n     (xio_resetn),
      .psel      (psel && clk_sel),
      .penable   (penable),
      .pwrite    (pwrite),
      .paddr     (paddr[7:0]),
      .pwdata    (pwdata),
      .prdata    (clk_prdata),
      .pll_en    (pll_en),
      .pll_bp    (pll_bp),
      .pll_n     (pll_n),
      .pll_select(pll_select),
      .pll_od    (pll_od),
      .pll_refclk(pll_refclk),
      .pll_ckout (pll_ckout),
      .lclk      (sd_lclk),
      .clk_out   (clk_out)
  );

  sysctl sys (
      .clk    (clk),
      .rst_n  (xio_resetn),
      .psel   (psel && sys_sel),
      .penable(penable),
      .pwrite (pwrite),
      .paddr  (paddr[7:0]),
      .pwdata (pwdata),
      .prdata (sys_prdata),
      .padsel (padsel)
  );

  assign pready  = eth_sel ? eth_pready : io_sel ? io_pready : 1'b1;
  assign prdata  = eth_sel ? eth_prdata : io_sel ? io_prdata : sd_sel ? sd_prdata : sdm_sel ? sdm_prdata :
                   sys_sel ? sys_prdata : clk_sel ? clk_prdata : 32'h0;
  assign pslverr = eth_sel ? eth_pslverr : io_sel && io_pslverr;
  // 以太网插回 soc-io 原先给它的第 12 位，后面两个的中断号不动
  assign xio_irq = {4'b0, sd_irq, 1'b0, io_irqs[13:12], eth_irq, io_irqs[11:0]};
endmodule
`default_nettype wire
