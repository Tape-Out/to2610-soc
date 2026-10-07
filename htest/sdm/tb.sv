// sdm 的单元测试。板上那一半用累加器当电容：每拍加上「被测电压」与「反馈」各自相对门限的差，大于零输入脚读到 1；
// 电容上的电压出不了电源的两头，累加器也封顶。
//   寄存器  标识、复位值、WIN 的上下限、PINS
//   DAC     六万五千五百三十六个节拍里一的个数正好等于设定值，两路各验一个数；PRE 管着节拍的宽度
//   ADC     输入钉在高、低时读数正好是满与零；三个直流电平的读数差不过 4（环路里有三拍的延迟，不是理想的一阶）；
//           有新结果的那一位读一次清掉
//   闭环    第 1 路 ADC 量第 0 路 DAC 的码流
`timescale 1ns / 1ps
module tb;
  localparam ID = 8'h00, CTRL = 8'h04, DAC0 = 8'h08, DAC1 = 8'h0c, ADC0 = 8'h10, ADC1 = 8'h14, WIN = 8'h18, PRE = 8'h1c;
  localparam int FULL = 65536;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg         psel = 0, penable = 0, pwrite = 0;
  reg  [ 7:0] paddr = 0;
  reg  [31:0] pwdata = 0;
  wire [31:0] prdata;
  wire        pins;
  wire [ 1:0] dac, adc_fb;
  reg  [ 1:0] adc_in = 0;

  sdm dut (
      .clk(clk), .rst_n(rst_n), .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
      .prdata(prdata), .pins(pins), .dac(dac), .adc_fb(adc_fb), .adc_in(adc_in)
  );

  // 板上的两个电容。mode：0 照 vin 的直流电平，1 钉高，2 钉低；第 1 路还有 3：量 DAC0 的码流
  int vin0 = 0, vin1 = 0, mode0 = 0, mode1 = 0;
  localparam int SAT = 8 * FULL;
  int n0 = 0, n1 = 0;
  function automatic int clamp(input int x);
    clamp = x > SAT ? SAT : x < -SAT ? -SAT : x;
  endfunction
  always @(posedge clk) begin
    n0 <= clamp(n0 + vin0 + (adc_fb[0] ? FULL : 0) - FULL);
    n1 <= clamp(n1 + (mode1 == 3 ? (dac[0] ? FULL : 0) : vin1) + (adc_fb[1] ? FULL : 0) - FULL);
    adc_in[0] <= mode0 == 1 ? 1'b1 : mode0 == 2 ? 1'b0 : n0 > 0;
    adc_in[1] <= mode1 == 1 ? 1'b1 : mode1 == 2 ? 1'b0 : n1 > 0;
  end

  int errs = 0;
  task automatic check(input bit ok, input string what);
    if (!ok) begin
      errs++;
      $display("FAIL %s（%0t）", what, $time);
    end
  endtask

  task automatic wr(input [7:0] a, input [31:0] d);
    @(posedge clk); psel <= 1; pwrite <= 1; paddr <= a; pwdata <= d;
    @(posedge clk); penable <= 1;
    @(posedge clk); psel <= 0; penable <= 0; pwrite <= 0;
  endtask

  task automatic rd(input [7:0] a, output [31:0] d);
    @(posedge clk); psel <= 1; pwrite <= 0; paddr <= a;
    @(posedge clk); penable <= 1;
    @(posedge clk); d = prdata; psel <= 0; penable <= 0;
  endtask

  // 数 n 拍里某根线是高的拍数
  task automatic ones(input int which, input int n, output int c);
    c = 0;
    repeat (n) begin
      @(posedge clk);
      c += which == 0 ? dac[0] : dac[1];
    end
  endtask

  // 等第 k 路 ADC 出一个新结果，丢掉头一个（开着的那一刻窗口是半截的），取第二个
  task automatic adc(input int k, output int c);
    reg [31:0] v;
    repeat (2) begin
      rd(k == 0 ? ADC0 : ADC1, v);
      while (!v[31]) rd(k == 0 ? ADC0 : ADC1, v);
    end
    c = v[16:0];
  endtask

  reg [31:0] v;
  int        c, lvl[3] = '{32'h2000, 32'h8000, 32'he000};
  initial begin
    repeat (4) @(posedge clk);
    rst_n <= 1;
    repeat (2) @(posedge clk);

    rd(ID, v);
    check(v == 32'h53444d31, "标识不对");
    rd(CTRL, v);
    check(v == 0 && !pins && dac == 0 && adc_fb == 0, "复位后不是全关");
    rd(WIN, v);
    check(v == 12, "WIN 的复位值不是 12");
    rd(PRE, v);
    check(v == 9, "PRE 的复位值不是 9");
    wr(WIN, 2);
    rd(WIN, v);
    check(v == 4, "WIN 写 2 没被抬到 4");
    wr(WIN, 31);
    rd(WIN, v);
    check(v == 16, "WIN 写 31 没被压到 16");
    wr(CTRL, 32'h100);
    rd(CTRL, v);
    check(v == 32'h100 && pins, "PINS 没起来");

    // PRE：一半满幅时码流一个节拍高、一个节拍低，节拍是 PRE+1 拍
    wr(PRE, 3);
    wr(DAC0, 32'h8000);
    wr(CTRL, 32'h1);
    repeat (40) @(posedge clk);
    while (!dac[0]) @(posedge clk);
    while (dac[0]) @(posedge clk);
    c = 0;
    while (!dac[0]) begin
      @(posedge clk);
      c++;
    end
    check(c == 4, $sformatf("PRE 写 3，一个节拍却是 %0d 拍", c));
    wr(CTRL, 0);

    // DAC：一的个数正好等于设定值
    wr(PRE, 0);
    wr(DAC0, 32'h4000);
    wr(DAC1, 32'hc001);
    wr(CTRL, 32'h3);
    repeat (8) @(posedge clk);
    ones(0, FULL, c);
    check(c == 32'h4000, $sformatf("DAC0 设 0x4000，六万五千五百三十六拍里有 %0d 个一", c));
    ones(1, FULL, c);
    check(c == 32'hc001, $sformatf("DAC1 设 0xc001，六万五千五百三十六拍里有 %0d 个一", c));
    wr(CTRL, 0);
    repeat (4) @(posedge clk);
    check(dac == 0, "关掉之后 DAC 还在出");

    // ADC：钉高钉低是满与零，三个直流电平
    wr(WIN, 10);
    mode0 = 1;
    wr(CTRL, 32'h4);
    adc(0, c);
    check(c == 1024, $sformatf("输入钉高，读数是 %0d，该是 1024", c));
    rd(ADC0, v);
    check(!v[31], "读过一次，有新结果的那一位还在");
    mode0 = 2;
    adc(0, c);
    check(c == 0, $sformatf("输入钉低，读数是 %0d，该是 0", c));
    mode0 = 0;
    for (int i = 0; i < 3; i++) begin
      vin0 = lvl[i];
      adc(0, c);
      check(c >= lvl[i] / 64 - 4 && c <= lvl[i] / 64 + 4, $sformatf("电平 %0d/65536，读数 %0d，该在 %0d 上下", lvl[i], c, lvl[i] / 64));
    end
    wr(CTRL, 0);
    repeat (4) @(posedge clk);
    check(adc_fb == 0, "关掉之后反馈脚还在动");

    // 闭环：第 1 路 ADC 量第 0 路 DAC
    mode1 = 3;
    wr(DAC0, 32'h6000);
    wr(CTRL, 32'h9);
    adc(1, c);
    check(c >= 384 - 5 && c <= 384 + 5, $sformatf("DAC0 设 0x6000，ADC1 读到 %0d，该在 384 上下", c));

    if (errs == 0) $display("sdm ok");
    else $display("sdm FAIL：%0d 处", errs);
    $finish;
  end

  initial begin
    repeat (4000000) @(posedge clk);
    $display("sdm FAIL：超时");
    $finish;
  end
endmodule
