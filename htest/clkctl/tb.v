// 时钟控制、PLL 与 SerDes 一起：两颗「芯片」各有自己的 50 MHz 晶振（差 600 ppm）、PLL 与时钟控制，线上带 0 至 6 纳秒的抖动。
// 依次核对：寄存器的复位值；旁路时量到参考时钟的一半；五组倍频与分频各自量到的频率；不合法的组合量到 0；
// clk_out 脚；SerDes 换到 PLL 分出来的时钟上自环；两颗对接跑 PRBS 零误码；两边换一档速率再对接；
// 两边速率不同就锁不上；切回系统时钟照样通。
`timescale 1ns / 1ps
module apb_bfm (
    input  wire        pclk,
    output reg         psel,
    output reg         penable,
    output reg         pwrite,
    output reg  [ 8:0] paddr,
    output reg  [31:0] pwdata,
    input  wire [31:0] prdata
);
  initial begin
    psel = 1'b0;
    penable = 1'b0;
    pwrite = 1'b0;
    paddr = 9'd0;
    pwdata = 32'd0;
  end

  task write(input [8:0] a, input [31:0] d);
    begin
      @(posedge pclk); #1 psel = 1'b1; pwrite = 1'b1; paddr = a; pwdata = d;
      @(posedge pclk); #1 penable = 1'b1;
      @(posedge pclk); #1 psel = 1'b0; penable = 1'b0; pwrite = 1'b0;
    end
  endtask

  task read(input [8:0] a, output [31:0] d);
    begin
      @(posedge pclk); #1 psel = 1'b1; pwrite = 1'b0; paddr = a;
      @(posedge pclk); #1 penable = 1'b1;
      @(posedge pclk); d = prdata; #1 psel = 1'b0; penable = 1'b0;
    end
  endtask
endmodule

// 一颗芯片里与时钟有关的那一角：地址第 8 位为 0 是时钟控制，为 1 是 SerDes
module chip (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [ 8:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        lclk,
    output wire        clk_out,
    output wire        tx,
    input  wire        rx
);
  wire [31:0] c_rd, s_rd;
  wire        en, bp, select, refclk, ckout;
  wire [ 7:0] n;
  wire [ 1:0] od;
  supply1     vdd;
  supply0     vss;

  clkctl #(
      .PLL(1)
  ) c (
      .clk(clk), .rst_n(rst_n), .psel(psel && !paddr[8]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr[7:0]), .pwdata(pwdata), .prdata(c_rd),
      .pll_en(en), .pll_bp(bp), .pll_n(n), .pll_select(select), .pll_od(od), .pll_refclk(refclk), .pll_ckout(ckout),
      .lclk(lclk), .clk_out(clk_out)
  );
  PLL_TOP pll (
      .EN(en), .BP(bp), .N(n), .SELECT(select), .OD(od), .REFCLK(refclk),
      .AVDD(vdd), .AVSS(vss), .DVDD(vdd), .DVSS(vss), .DVDD_DRV(vdd), .DVSS_DRV(vss),
      .CKOUT1(ckout), .CKOUT2(), .CKTST()
  );
  serdes_apb sd (
      .pclk(clk), .presetn(rst_n), .psel(psel && paddr[8]), .penable(penable), .pwrite(pwrite),
      .paddr(paddr[7:0]), .pwdata(pwdata), .prdata(s_rd), .irq(), .lclk(lclk), .tx(tx), .rx(rx)
  );
  assign prdata = paddr[8] ? s_rd : c_rd;
endmodule

module tb;
  localparam ID = 9'h000, PLL = 9'h004, DIV = 9'h008, FREQ = 9'h00c;
  localparam SCTRL = 9'h104, SCMD = 9'h108, SSTAT = 9'h10c, STX = 9'h110, SRX = 9'h114, SNPB = 9'h124, SNPE = 9'h128;
  localparam P_EN = 32'h20000, P_BP = 32'h10000, D_OUT = 32'h10000, D_SRC = 32'h20000;
  localparam S_EN = 32'h1, S_LOOP = 32'h2, S_PTX = 32'h4, S_PRX = 32'h8;

  reg ca = 1'b0, cb = 1'b0, rst_n = 1'b1;
  always #10.000 ca = ~ca;
  always #10.006 cb = ~cb;

  wire        a_psel, a_pen, a_pwr, b_psel, b_pen, b_pwr;
  wire [ 8:0] a_addr, b_addr;
  wire [31:0] a_wd, a_rd, b_wd, b_rd;
  wire        a_lclk, b_lclk, a_out, b_out, a_tx, b_tx;
  reg         a2b = 1'b0, b2a = 1'b0;
  always @(a_tx) a2b <= #({$random} % 7) a_tx;
  always @(b_tx) b2a <= #({$random} % 7) b_tx;

  apb_bfm ma (.pclk(ca), .psel(a_psel), .penable(a_pen), .pwrite(a_pwr), .paddr(a_addr), .pwdata(a_wd), .prdata(a_rd));
  apb_bfm mb (.pclk(cb), .psel(b_psel), .penable(b_pen), .pwrite(b_pwr), .paddr(b_addr), .pwdata(b_wd), .prdata(b_rd));
  chip a (.clk(ca), .rst_n(rst_n), .psel(a_psel), .penable(a_pen), .pwrite(a_pwr), .paddr(a_addr), .pwdata(a_wd),
          .prdata(a_rd), .lclk(a_lclk), .clk_out(a_out), .tx(a_tx), .rx(b2a));
  chip b (.clk(cb), .rst_n(rst_n), .psel(b_psel), .penable(b_pen), .pwrite(b_pwr), .paddr(b_addr), .pwdata(b_wd),
          .prdata(b_rd), .lclk(b_lclk), .clk_out(b_out), .tx(b_tx), .rx(a2b));

  integer errs = 0;
  task check(input ok, input string what);
    begin
      // 判据里有 X 也算不过：if (!ok) 遇到 X 是不进分支的
      if (ok !== 1'b1) begin
        errs = errs + 1;
        $display("FAIL %0s（%0t）", what, $time);
      end
    end
  endtask

  reg [31:0] v, w;
  integer    i, n;

  // 量一次频率：改过设置之后头两个窗口可能是半截的，取第三个
  task a_freq(output integer f);
    begin
      repeat (3) begin
        ma.read(FREQ, v);
        while (!v[31]) ma.read(FREQ, v);
      end
      f = v[23:0];
    end
  endtask

  // 改 PLL 的设置照宏的说明走：先关 EN 把数设好，再开
  task a_pll(input [31:0] pll);
    begin
      ma.write(PLL, pll & ~P_EN);
      ma.write(PLL, pll);
    end
  endtask
  task b_pll(input [31:0] pll);
    begin
      mb.write(PLL, pll & ~P_EN);
      mb.write(PLL, pll);
    end
  endtask

  // 设一组倍频与分频，量到的该是 want（窗口 65536 个系统时钟，所以 65536 对应与系统时钟同频）
  task a_set(input [31:0] pll, input [31:0] div, input integer want, input string what);
    integer f;
    begin
      a_pll(pll);
      ma.write(DIV, div);
      a_freq(f);
      check(f >= want - 2 && f <= want + 2, $sformatf("%0s：量到 %0d，该是 %0d", what, f, want));
    end
  endtask

  // 数某根线在 2 微秒里的上升沿
  integer n_lclk = 0, n_out = 0;
  always @(posedge a_lclk) n_lclk = n_lclk + 1;
  always @(posedge a_out) n_out = n_out + 1;
  task edges(input which, output integer c);
    integer c0;
    begin
      c0 = which ? n_lclk : n_out;
      #2000;
      c = (which ? n_lclk : n_out) - c0;
    end
  endtask

  task s_wait(input [31:0] mask, input [31:0] want, input integer t);
    integer t0;
    begin
      t0 = $time;
      ma.read(SSTAT, v);
      mb.read(SSTAT, w);
      while (((v & mask) != want || (w & mask) != want) && $time - t0 < t) begin
        ma.read(SSTAT, v);
        mb.read(SSTAT, w);
      end
    end
  endtask

  // 两边都跑 PRBS，过 t 纳秒抓一次计数：字节够多、误码是零
  task prbs_pair(input integer t, input string what);
    begin
      ma.write(SCTRL, S_EN | S_PTX | S_PRX);
      mb.write(SCTRL, S_EN | S_PTX | S_PRX);
      #(t / 4);
      ma.write(SCMD, 32'h2);
      mb.write(SCMD, 32'h2);
      #(t);
      ma.write(SCMD, 32'h4);
      mb.write(SCMD, 32'h4);
      s_wait(32'h20, 32'h0, 200000);
      ma.read(SNPB, v);
      mb.read(SNPB, w);
      check(v > 32'd200 && w > 32'd200, $sformatf("%0s：核过的字节太少（%0d、%0d）", what, v, w));
      ma.read(SNPE, v);
      mb.read(SNPE, w);
      check(v == 32'd0 && w == 32'd0, $sformatf("%0s：有误码（%0d、%0d）", what, v, w));
      ma.write(SCTRL, S_EN);
      mb.write(SCTRL, S_EN);
    end
  endtask

  initial begin
    // 复位要有一个真的下降沿：PLL 那一侧在复位期间没有时钟，异步复位的触发器全靠这个沿
    #1 rst_n = 1'b0;
    repeat (5) @(posedge ca);
    rst_n = 1'b1;
    repeat (5) @(posedge ca);

    ma.read(ID, v);
    check(v == 32'h434c4b31, "标识不对");
    ma.read(PLL, v);
    check(v == 32'h00010620, "PLL 的复位值不是旁路、N 32、OD 8 分频");
    ma.read(DIV, v);
    check(v == 32'h0, "DIV 的复位值不是 0");

    // 旁路：PLL 出的就是 25 MHz 的参考，再除以 2
    a_freq(n);
    check(n >= 16382 && n <= 16386, $sformatf("旁路时量到 %0d，该是 16384", n));
    ma.read(FREQ, v);
    check(!v[31], "读过一次，有新结果的那一位还在");

    a_set(P_EN | 32'h620, 32'h0, 65536, "N 32、OD 8、D 0（100 MHz 除以 2）");
    a_set(P_EN | 32'h620, 32'h1, 32768, "N 32、OD 8、D 1（100 MHz 除以 4）");
    a_set(P_EN | 32'h420, 32'h1, 65536, "N 32、OD 4、D 1（200 MHz 除以 4）");
    a_set(P_EN | 32'h628, 32'h0, 81920, "N 40、OD 8、D 0（125 MHz 除以 2）");
    a_set(P_EN | 32'h714, 32'h0, 81920, "N 20、SELECT、OD 8、D 0（125 MHz 除以 2）");
    a_set(P_EN | 32'h610, 32'h0, 0, "N 16 不合法，不该有时钟");

    // clk_out 脚与线路时钟
    a_pll(P_EN | 32'h620);
    ma.write(DIV, D_OUT);
    #40000;
    edges(1'b0, n);
    check(n >= 99 && n <= 101, $sformatf("OUT 开着，clk_out 两微秒里 %0d 个沿，该是 100", n));
    edges(1'b1, n);
    check(n >= 99 && n <= 101, $sformatf("SRC 没开，线路时钟两微秒里 %0d 个沿，该是系统时钟的 100", n));
    ma.write(DIV, 32'h0);
    #1000;
    edges(1'b0, n);
    check(n == 0, "OUT 关了，clk_out 还在动");

    // SerDes 换到 PLL 分出来的时钟上：先 100 MHz（OD 4、D 0），自环
    a_pll(P_EN | 32'h420);
    ma.write(DIV, D_SRC);
    #40000;
    edges(1'b1, n);
    check(n >= 199 && n <= 201, $sformatf("SRC 开了，线路时钟两微秒里 %0d 个沿，该是 200", n));
    ma.write(SCTRL, S_EN | S_LOOP);
    ma.read(SSTAT, v);
    i = $time;
    while (!v[1] && $time - i < 400000) ma.read(SSTAT, v);
    check(v[1], "PLL 的时钟下自环没锁上");
    for (i = 0; i < 6; i = i + 1) ma.write(STX, 32'h30 + i);
    for (i = 0; i < 6; i = i + 1) begin
      ma.read(SSTAT, v);
      while (!v[3]) ma.read(SSTAT, v);
      ma.read(SRX, v);
      check(v == (32'h80000030 + i), "PLL 的时钟下自环收回来的不对");
    end

    // 两颗对接，各自的晶振、各自的 PLL，线路时钟 100 MHz、线速率 25 Mbit/s
    b_pll(P_EN | 32'h420);
    mb.write(DIV, D_SRC);
    ma.write(SCTRL, S_EN);
    mb.write(SCTRL, S_EN);
    s_wait(32'h2, 32'h2, 600000);
    check(v[1] && w[1], "两颗在 25 Mbit/s 上对接没锁上");
    prbs_pair(400000, "25 Mbit/s 对接");

    // 换一档：两边都是 50 MHz 的线路时钟（OD 8、D 0），12.5 Mbit/s
    a_pll(P_EN | 32'h620);
    b_pll(P_EN | 32'h620);
    s_wait(32'h2, 32'h2, 800000);
    check(v[1] && w[1], "两颗在 12.5 Mbit/s 上对接没锁上");
    prbs_pair(800000, "12.5 Mbit/s 对接");

    // 两边速率不同：锁不上
    b_pll(P_EN | 32'h420);
    #400000;
    ma.read(SSTAT, v);
    mb.read(SSTAT, w);
    check(!(v[1] && w[1]), "两边线速率差一倍还报锁着");

    // 切回系统时钟，两边都是 12.5 Mbit/s
    ma.write(DIV, 32'h0);
    mb.write(DIV, 32'h0);
    s_wait(32'h2, 32'h2, 800000);
    check(v[1] && w[1], "切回系统时钟没锁上");
    prbs_pair(800000, "系统时钟下对接");

    if (errs == 0) $display("PASS tb_clk");
    else $display("FAIL tb_clk：%0d 处", errs);
    $finish;
  end

  initial begin
    #80000000;
    $display("FAIL tb_clk：超时");
    $finish;
  end
endmodule
