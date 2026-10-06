// KianV 的片上总线转 APB4：地址窗里的一次访问变成一次 APB 传输。
// 核把请求顶着直到应答，应答只给一拍；从设备报错时读回 0，不另起陷入。
`default_nettype none
module kv_apb (
    input  wire        clk,
    input  wire        resetn,
    input  wire        bus_valid_i,
    input  wire [31:0] bus_addr_i,
    input  wire [ 3:0] bus_wstrb_i,
    input  wire [31:0] bus_wdata_i,
    output reg  [31:0] bus_rdata_o,
    output reg         bus_ready_o,

    output reg         psel,
    output reg         penable,
    output reg         pwrite,
    output reg  [27:0] paddr,
    output reg  [31:0] pwdata,
    output reg  [ 3:0] pstrb,
    input  wire        pready,
    input  wire [31:0] prdata,
    input  wire        pslverr
);
  always @(posedge clk) begin
    if (!resetn) begin
      psel        <= 1'b0;
      penable     <= 1'b0;
      pwrite      <= 1'b0;
      paddr       <= 28'h0;
      pwdata      <= 32'h0;
      pstrb       <= 4'h0;
      bus_ready_o <= 1'b0;
      bus_rdata_o <= 32'h0;
    end else begin
      bus_ready_o <= 1'b0;
      if (!psel) begin
        // 应答的那一拍请求还顶着，不能当成下一次
        if (bus_valid_i && !bus_ready_o) begin
          psel   <= 1'b1;
          pwrite <= |bus_wstrb_i;
          paddr  <= bus_addr_i[27:0];
          pwdata <= bus_wdata_i;
          pstrb  <= bus_wstrb_i;
        end
      end else if (!penable) begin
        penable <= 1'b1;
      end else if (pready) begin
        psel        <= 1'b0;
        penable     <= 1'b0;
        bus_rdata_o <= pslverr ? 32'h0 : prdata;
        bus_ready_o <= 1'b1;
      end
    end
  end
endmodule
`default_nettype wire
