// 片上的杂项寄存器，APB 从口，零等待。
//   0x00 ID      只读，0x534F4331（"SOC1"）
//   0x04 PADSEL  每个复用焊盘两位，第 2k+1:2k 位管第 k 个；复位全 0。只有 Frame 形态用它，排法在 soc_frame.v
`default_nettype none
module sysctl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [ 7:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output reg  [23:0] padsel
);
  always @(posedge clk) begin
    if (!rst_n) padsel <= 24'h0;
    else if (psel && penable && pwrite && paddr[7:2] == 6'h01) padsel <= pwdata[23:0];
  end

  assign prdata = paddr[7:2] == 6'h00 ? 32'h534F_4331 : paddr[7:2] == 6'h01 ? {8'h00, padsel} : 32'h0;
endmodule
`default_nettype wire
