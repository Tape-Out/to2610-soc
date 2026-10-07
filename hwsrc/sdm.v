// 两路数字式 DAC 与两路数字式 ADC，都是一阶 ΣΔ，片上只有触发器与加法器，模拟的那一半在板上。APB 从口，零等待。
//   DAC  累加器每个节拍加上设定值，进位就是输出的那一位：一的密度是 设定值/65536。板上一颗电阻一颗电容滤出电压
//   ADC  被测电压与反馈脚各经一颗电阻汇到一颗电容上，电容接输入脚。输入脚读到 1 就把反馈拉低、读到 0 就拉高，
//        电容上的电压被按在输入脚的翻转门限附近；一个窗口里读到 1 的次数正比于被测电压
//
//   0x00 ID     只读，0x53444D31（"SDM1"）
//   0x04 CTRL   第 0、1 位开 DAC0、DAC1，第 2、3 位开 ADC0、ADC1，第 8 位 PINS：六根脚接管 GPIO 1 的第 6 至 11 位
//               （依次是 DAC0、DAC1、ADC0 的反馈、ADC0 的输入、ADC1 的反馈、ADC1 的输入）
//   0x08 DAC0   0x0C DAC1   低 16 位是设定值
//   0x10 ADC0   0x14 ADC1   低 17 位是上一个窗口里读到 1 的次数，第 31 位是有新结果，读一次清掉
//   0x18 WIN    低 5 位：窗口是 2^WIN 个节拍，4 至 16，复位 12
//   0x1C PRE    低 8 位：每 PRE+1 个时钟一个节拍，复位 9（50 MHz 下码流 5 MHz）
`default_nettype none
module sdm (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [ 7:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pins,
    output wire [ 1:0] dac,
    output wire [ 1:0] adc_fb,
    input  wire [ 1:0] adc_in
);
  wire       wr = psel && penable && pwrite;
  wire       rd = psel && penable && !pwrite;
  wire [2:0] sel = paddr[4:2];

  reg [ 3:0] en;
  reg        take;
  reg [15:0] val0, val1;
  reg [ 4:0] win;
  reg [ 7:0] pre;
  always @(posedge clk) begin
    if (!rst_n) begin
      en   <= 4'h0;
      take <= 1'b0;
      val0 <= 16'h0;
      val1 <= 16'h0;
      win  <= 5'd12;
      pre  <= 8'd9;
    end else if (wr) begin
      case (sel)
        3'd1: begin
          en   <= pwdata[3:0];
          take <= pwdata[8];
        end
        3'd2: val0 <= pwdata[15:0];
        3'd3: val1 <= pwdata[15:0];
        3'd6: win <= pwdata[4:0] < 5'd4 ? 5'd4 : pwdata[4:0] > 5'd16 ? 5'd16 : pwdata[4:0];
        3'd7: pre <= pwdata[7:0];
        default: ;
      endcase
    end
  end

  reg  [7:0] div;
  wire       tick = div == 8'd0;
  always @(posedge clk) begin
    if (!rst_n) div <= 8'd0;
    else div <= tick ? pre : div - 8'd1;
  end

  wire [16:0] cnt[0:1];
  wire [ 1:0] fresh;
  genvar k;
  generate
    for (k = 0; k < 2; k = k + 1) begin : ch
      wire [15:0] val = k == 0 ? val0 : val1;
      reg  [15:0] acc;
      reg         bit_q;
      wire [16:0] sum = {1'b0, acc} + {1'b0, val};
      always @(posedge clk) begin
        if (!rst_n || !en[k]) begin
          acc   <= 16'h0;
          bit_q <= 1'b0;
        end else if (tick) begin
          acc   <= sum[15:0];
          bit_q <= sum[16];
        end
      end
      assign dac[k] = bit_q;

      // 输入脚是板上来的，与时钟无关：打两拍
      reg  [ 1:0] in_s;
      reg         fb_q, fresh_q;
      reg  [16:0] ones, held, n;
      wire        last = n == (17'd1 << win) - 17'd1;
      always @(posedge clk) begin
        if (!rst_n) in_s <= 2'b00;
        else in_s <= {in_s[0], adc_in[k]};
      end
      always @(posedge clk) begin
        if (!rst_n || !en[2+k]) begin
          fb_q    <= 1'b0;
          fresh_q <= 1'b0;
          ones    <= 17'd0;
          held    <= 17'd0;
          n       <= 17'd0;
        end else begin
          if (rd && sel == 3'd4 + k) fresh_q <= 1'b0;
          if (tick) begin
            fb_q <= !in_s[1];
            n    <= last ? 17'd0 : n + 17'd1;
            ones <= last ? 17'd0 : ones + {16'd0, in_s[1]};
            if (last) begin
              held    <= ones + {16'd0, in_s[1]};
              fresh_q <= 1'b1;
            end
          end
        end
      end
      assign adc_fb[k] = fb_q;
      assign cnt[k]    = held;
      assign fresh[k]  = fresh_q;
    end
  endgenerate

  always @(*) begin
    case (sel)
      3'd0: prdata = 32'h5344_4D31;
      3'd1: prdata = {23'd0, take, 4'd0, en};
      3'd2: prdata = {16'd0, val0};
      3'd3: prdata = {16'd0, val1};
      3'd4: prdata = {fresh[0], 14'd0, cnt[0]};
      3'd5: prdata = {fresh[1], 14'd0, cnt[1]};
      3'd6: prdata = {27'd0, win};
      default: prdata = {24'd0, pre};
    endcase
  end

  assign pins = take;
endmodule
`default_nettype wire
