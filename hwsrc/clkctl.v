// 时钟控制：管片上的 PLL 宏、它后面的分频、SerDes 的线路时钟取哪一路，并拿系统时钟量分出来的频率。APB 从口，零等待。
//   0x00 ID    只读，0x434C4B31（"CLK1"）
//   0x04 PLL   7:0 N（反馈分频，要大于 16，复位 32）；第 8 位 SELECT（反馈再乘 2）；10:9 OD（输出分频 1、2、4、8，复位是 8 那一档）；
//              第 16 位 BP（旁路，PLL 的输出就是参考时钟，复位 1）；第 17 位 EN（复位 0）
//   0x08 DIV   7:0 D：PLL 的输出再除以 2 ×（D + 1），复位 0；第 16 位 OUT：把分出来的时钟送到 clk_out 脚；
//              第 17 位 SRC：SerDes 的线路时钟取分出来的这一路，0 是系统时钟
//   0x0C FREQ  只读：上一个窗口（65536 个系统时钟）里分出来的时钟走了几个周期；第 31 位是有新结果，读一次清掉
// 参考时钟是系统时钟的二分频（宏要 5 至 40 MHz）。VCO = 参考 × N ×（SELECT ? 2 : 1），要落在 500 至 1200 MHz，
// PLL 出的是 VCO 除以 OD 那一档。寄存器不拦不合法的组合，量出来的 FREQ 是 0 就是没起振。
// 改 N、SELECT、OD 照宏的说明走：先把 EN 写 0，设好，再把 EN 写 1。设错了没起振的，也要这样重来一次。
//
// PLL 为 0 时没有宏（Frame 形态）：寄存器照样读写，线路时钟恒是系统时钟，FREQ 恒是 0，时钟路径上不多一个门。
// 切 SRC 之前先看 FREQ 有数：两路时钟各在自己的下降沿上交接，对面那一路不走，这一路就接不过来。
`default_nettype none
module clkctl #(
    parameter PLL = 1
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [ 7:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,

    output wire        pll_en,
    output wire        pll_bp,
    output wire [ 7:0] pll_n,
    output wire        pll_select,
    output wire [ 1:0] pll_od,
    output wire        pll_refclk,
    input  wire        pll_ckout,

    output wire        lclk,
    output wire        clk_out
);
  wire       wr = psel && penable && pwrite;
  wire       rd = psel && penable && !pwrite;
  wire [1:0] sel = paddr[3:2];

  reg [7:0] n, d;
  reg       select, bp, en, out, src;
  reg [1:0] od;
  always @(posedge clk) begin
    if (!rst_n) begin
      n      <= 8'd32;
      select <= 1'b0;
      od     <= 2'd3;
      bp     <= 1'b1;
      en     <= 1'b0;
      d      <= 8'd0;
      out    <= 1'b0;
      src    <= 1'b0;
    end else if (wr && sel == 2'd1) begin
      n      <= pwdata[7:0];
      select <= pwdata[8];
      od     <= pwdata[10:9];
      bp     <= pwdata[16];
      en     <= pwdata[17];
    end else if (wr && sel == 2'd2) begin
      d   <= pwdata[7:0];
      out <= pwdata[16];
      src <= pwdata[17];
    end
  end

  assign pll_en     = en;
  assign pll_bp     = bp;
  assign pll_n      = n;
  assign pll_select = select;
  assign pll_od     = od;

  wire [23:0] freq;
  wire        fresh;
  generate
    if (PLL != 0) begin : on
      reg ref_q;
      always @(posedge clk) begin
        if (!rst_n) ref_q <= 1'b0;
        else ref_q <= !ref_q;
      end
      assign pll_refclk = ref_q;

      // PLL 那一侧的复位：异步落下，同步松开。PLL 没出时钟时这一侧就一直按着
      reg [1:0] rst_c;
      always @(posedge pll_ckout or negedge rst_n) begin
        if (!rst_n) rst_c <= 2'b00;
        else rst_c <= {rst_c[0], 1'b1};
      end

      reg [7:0] d1, d2, cnt;
      reg       q;
      reg [23:0] edges;
      always @(posedge pll_ckout or negedge rst_c[1]) begin
        if (!rst_c[1]) begin
          d1    <= 8'd0;
          d2    <= 8'd0;
          cnt   <= 8'd0;
          q     <= 1'b0;
          edges <= 24'd0;
        end else begin
          d1 <= d;
          d2 <= d1;
          // D 在跑着的时候改小，计数器可能已经过了新的上限：比大于等于，不比等于
          if (cnt >= d2) begin
            cnt <= 8'd0;
            q   <= !q;
            if (!q) edges <= edges + 24'd1;
          end else cnt <= cnt + 8'd1;
        end
      end

      // 量频率：分出来的时钟每个周期把 edges 加一，格雷码过到系统时钟这一侧，每个窗口取一次差
      wire [23:0] gray = edges ^ (edges >> 1);
      reg  [23:0] gray_q, g1, g2;
      always @(posedge pll_ckout or negedge rst_c[1]) begin
        if (!rst_c[1]) gray_q <= 24'd0;
        else gray_q <= gray;
      end
      reg [23:0] bin;
      integer    i;
      always @(*) begin
        bin[23] = g2[23];
        for (i = 22; i >= 0; i = i - 1) bin[i] = bin[i+1] ^ g2[i];
      end
      reg [15:0] win;
      reg [23:0] last, freq_q;
      reg        fresh_q;
      always @(posedge clk) begin
        if (!rst_n) begin
          g1      <= 24'd0;
          g2      <= 24'd0;
          win     <= 16'd0;
          last    <= 24'd0;
          freq_q  <= 24'd0;
          fresh_q <= 1'b0;
        end else begin
          g1  <= gray_q;
          g2  <= g1;
          win <= win + 16'd1;
          if (rd && sel == 2'd3) fresh_q <= 1'b0;
          if (win == 16'hffff) begin
            freq_q  <= bin - last;
            last    <= bin;
            fresh_q <= 1'b1;
          end
        end
      end
      assign freq  = freq_q;
      assign fresh = fresh_q;

      // 线路时钟两路选一路，不出毛刺：各在自己的下降沿上交接，先等对面关掉再开自己
      reg [1:0] a_s, b_s;
      always @(negedge clk or negedge rst_n) begin
        if (!rst_n) a_s <= 2'b00;
        else a_s <= {a_s[0], !src && !b_s[1]};
      end
      always @(negedge q or negedge rst_n) begin
        if (!rst_n) b_s <= 2'b00;
        else b_s <= {b_s[0], src && !a_s[1]};
      end
      assign lclk    = (clk & a_s[1]) | (q & b_s[1]);
      assign clk_out = q & out;
    end else begin : off
      assign pll_refclk = 1'b0;
      assign freq       = 24'd0;
      assign fresh      = 1'b0;
      assign lclk       = clk;
      assign clk_out    = 1'b0;
    end
  endgenerate

  always @(*) begin
    case (sel)
      2'd0: prdata = 32'h434C_4B31;
      2'd1: prdata = {14'd0, en, bp, 5'd0, od, select, n};
      2'd2: prdata = {14'd0, src, out, 8'd0, d};
      default: prdata = {fresh, 7'd0, freq};
    endcase
  end
endmodule
`default_nettype wire
