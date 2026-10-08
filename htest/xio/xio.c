/* 窗后面的外设逐个点一遍。寄存器偏移取息壤照各 IP 的 regmap.yaml 生成的头文件，地址取 soc-io 的装配。
 * 外设在各自的仓里都测过，这里验的是整片这一层才会错的三样：地址、引脚、中断号。
 * 引脚经 Frame 形态的 12 根复用焊盘出来，测试台按选的功能组接回环或最小的片外模型（htest/shim.py）。
 */
#include <stdint.h>

#include "can.h"
#include "crc.h"
#include "emac.h"

/* 以太网只在 MPW 形态里有（soc-eth），Frame 形态编的时候不给 ETH */
#ifndef ETH
#define ETH 0
#endif
#include "gpio.h"
#include "i2c.h"
#include "i2s.h"
#include "onew.h"
#include "ps2.h"
#include "pwm.h"
#include "rng.h"
#include "rtc.h"
#include "spi.h"
#include "timer.h"
#include "uart.h"
#include "wdt.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)
#define CSR_R(n) ({ uint32_t v_; __asm__ volatile("csrr %0, " #n : "=r"(v_)); v_; })
#define CSR_W(n, v) __asm__ volatile("csrw " #n ", %0" : : "r"((uint32_t)(v)))
#define CSR_S(n, v) __asm__ volatile("csrs " #n ", %0" : : "r"((uint32_t)(v)))

/* 程序就地在 Flash 里跑，没有 .data：中断里要记的几个数放在 SDRAM 里固定的地方 */
#define STATE ((volatile uint32_t *)0x80000100)
enum { CAUSE, COUNT, CLAIM };

#define XIO 0x40000000u
#define PAGE(n) (XIO + 0x1000u * (n))
#define UART1 PAGE(0)
#define GPIO1 PAGE(1)
#define TIMER0 PAGE(2)
#define WDT0 PAGE(3)
#define RTC0 PAGE(4)
#define I2C0 PAGE(5)
#define SPI2 PAGE(6)
#define ONEW0 PAGE(7)
#define I2S0 PAGE(8)
#define CAN0 PAGE(9)
#define PS2 PAGE(10)
#define RNG0 PAGE(11)
#define EMAC0 PAGE(12)
#define PWM0 PAGE(14)
#define CRC0 PAGE(15)
/* emac 的帧缓冲区 264 字（soc-io 里配的），前一半发、后一半收 */
#define EMAC_RX (264 / 2 * 4)
/* SerDes 在窗里的第 1 块，寄存器见 serdes 仓的 hwsrc/serdes_apb.v */
#define SD (XIO + 0x10000u)
enum { SD_CTRL = 0x04, SD_CMD = 0x08, SD_STAT = 0x0c, SD_TX = 0x10, SD_RX = 0x14, SD_NPBYTE = 0x24, SD_NPERR = 0x28 };
enum { SD_EN = 1, SD_LOOP = 2, SD_PTX = 4, SD_PRX = 8, SD_IE = 0x100 };
/* 数字式 ADC 与 DAC 在第 2 块，寄存器见 hwsrc/sdm.v */
#define SDM (XIO + 0x20000u)
enum { SDM_CTRL = 0x04, SDM_DAC0 = 0x08, SDM_ADC0 = 0x10, SDM_ADC1 = 0x14, SDM_WIN = 0x18, SDM_PRE = 0x1c };
/* 时钟控制在第 5 块，寄存器见 hwsrc/clkctl.v 开头 */
#define CLK (XIO + 0x50000u)
#define SYSCTL (XIO + 0x30000u)
#define PADSEL (SYSCTL + 4)
/* 12 根复用焊盘都选同一组 */
enum { F_GPIO = 0x000000, F_BUS = 0x555555, F_NET = 0xaaaaaa, F_SPI = 0xffffff };

#define PLIC 0x0c000000u
/* PLIC 的号是 11 加实例在 soc-io 里的次序 */
enum { UART1_IRQ = 11, GPIO1_IRQ, TIMER0_IRQ, SD_IRQ = 27 };

static void putch(char c) {
  while (!(LSR & 0x60)) {}
  REG(0x10000000) = c;
}

static void say(const char *s) {
  while (*s) putch(*s++);
}

static void hex(uint32_t v) {
  for (int i = 28; i >= 0; i -= 4) putch("0123456789abcdef"[v >> i & 15]);
}

static void verdict(const char *what, uint32_t bad, uint32_t detail) {
  say(what);
  say(bad ? " BAD " : " ok ");
  hex(detail);
  putch('\n');
}

__attribute__((interrupt("machine"), aligned(4))) static void trap(void) {
  uint32_t c = CSR_R(mcause);
  STATE[CAUSE] = c;
  STATE[COUNT]++;
  if (c == 0x8000000b) {
    uint32_t id = REG(PLIC + 0x200004);
    STATE[CLAIM] = id;
    /* 先把源头按下去再交还，否则刚交还又挂起 */
    if (id == UART1_IRQ) REG(UART1 + UART_IE) = 0;
    if (id == GPIO1_IRQ) REG(GPIO1 + GPIO_ISTA) = 0xffff;
    if (id == TIMER0_IRQ) REG(TIMER0 + TIMER_IEN) = 0;
    if (id == SD_IRQ) REG(SD + SD_CTRL) = SD_EN | SD_LOOP;
    REG(PLIC + 0x200004) = id;
  } else {
    say("trap ");
    hex(c);
    putch('\n');
    for (;;) {}
  }
}

/* 等一个条件，最多转 n 圈；回 1 是没等到 */
#define UNTIL(cond, n) ({ uint32_t t_ = 0; while (!(cond) && ++t_ < (n)) {} t_ >= (n); })

static uint32_t irq(uint32_t id) {
  STATE[COUNT] = STATE[CLAIM] = 0;
  REG(PLIC + 4 * id) = 1;
  REG(PLIC + 0x2000) = 1u << id;
  return id;
}

int main(void) {
  /* 主频寄存器是 8.8 定点的兆赫 */
  uint32_t hz = (REG(0x10000014) & 0xffff) * 15625 / 4;
  REG(0x1000000c) = hz / 115200;
  say("to2610 xio\n");
  STATE[CAUSE] = STATE[COUNT] = STATE[CLAIM] = 0;
  CSR_W(mtvec, (uint32_t)trap);
  REG(PLIC + 0x200000) = 0;
  REG(PLIC + 0x2000) = 0;
  CSR_S(mie, 1 << 11);
  CSR_S(mstatus, 1 << 3);
  uint32_t bad, got;

  /* 窗里没有东西的块读回 0，不陷入也不挂住；sysctl 认得出来 */
  verdict("hole", REG(XIO + 0x00f0000) != 0 || REG(XIO + 0x60000) != 0, REG(XIO + 0x00f0000));
  verdict("ident", REG(SYSCTL) != 0x534f4331, REG(SYSCTL));

  /* 地址：复位值各不相同的先看复位值，再给每个实例的一个可写寄存器写上各不相同的数、全部写完再读回。
   * 两个实例译到了同一页，或哪一页没人应，这里就对不上 */
  bad = REG(UART1 + UART_DIV) != 867 || REG(SPI2 + SPI_SCKDIV) != 3 || REG(ONEW0 + ONEW_TICK) != 99 ||
        REG(I2S0 + I2S_CTRL) != 16 << 8 || REG(CAN0 + CAN_BTR) != 0x00015c09 || REG(CRC0 + CRC_POLY) != 0x31;
  verdict("reset", bad, REG(CAN0 + CAN_BTR));
  static const uint32_t rw[] = {UART1 + UART_DIV,    GPIO1 + GPIO_IEN,  TIMER0 + TIMER_PRESC, WDT0 + WDT_LOAD,
                                RTC0 + RTC_CFG,      I2C0 + I2C_PRESC,  SPI2 + SPI_SCKDIV,    ONEW0 + ONEW_TICK,
                                I2S0 + I2S_DIV,      CAN0 + CAN_TXID,   PS2 + PS2_TICK,       RNG0 + RNG_CTRL,
                                EMAC0 + EMAC_MACLO,  PWM0 + PWM_PERIOD, CRC0 + CRC_SEED};
  /* 第 k 个写 k+1：最窄的那个寄存器（rtc 的 cfg、rng 的 ctrl）也放得下它要的那几位。
   * Frame 形态没有以太网，那一页空着，写了读回 0 */
  for (uint32_t k = 0; k < 15; k++) REG(rw[k]) = k == 11 ? 2 : k + 1;
  bad = 0;
  for (uint32_t k = 0; k < 15; k++) bad |= (REG(rw[k]) != (k == 11 ? 2 : k == 12 && !ETH ? 0 : k + 1)) << k;
  verdict("regs", bad, bad);
  for (uint32_t k = 0; k < 15; k++) REG(rw[k]) = 0;

  /* GPIO 1：低四位出、高四位读，再反过来；松手后读到上拉 */
  REG(PADSEL) = F_GPIO;
  REG(GPIO1 + GPIO_DIR) = 0x0f;
  REG(GPIO1 + GPIO_DOUT) = 0x05;
  got = REG(GPIO1 + GPIO_DIN) & 0xff;
  bad = got != 0x55;
  REG(GPIO1 + GPIO_DIR) = 0xf0;
  REG(GPIO1 + GPIO_DOUT) = 0xa0;
  got = got << 8 | (REG(GPIO1 + GPIO_DIN) & 0xff);
  bad |= (got & 0xff) != 0xaa;
  REG(GPIO1 + GPIO_DIR) = 0;
  got = got << 8 | (REG(GPIO1 + GPIO_DIN) & 0xff);
  bad |= (got & 0xff) != 0xff;
  verdict("gpio", bad, got);

  /* GPIO 的中断：第 0 根自己拉高，对接的第 4 根见到上升沿，经 PLIC 的 12 号进来 */
  irq(GPIO1_IRQ);
  REG(GPIO1 + GPIO_ISTA) = 0xffff;
  REG(GPIO1 + GPIO_IEN) = 0x10;
  REG(GPIO1 + GPIO_DIR) = 0x01;
  REG(GPIO1 + GPIO_DOUT) = 0x01;
  bad = UNTIL(STATE[COUNT], 20000);
  REG(GPIO1 + GPIO_IEN) = 0;
  REG(GPIO1 + GPIO_DIR) = 0;
  verdict("girq", bad || STATE[CAUSE] != 0x8000000b || STATE[CLAIM] != GPIO1_IRQ, STATE[CLAIM]);

  /* 串口 1：500 千波特，发四个字节、从回环收回来。RTS 接回 CTS，开了流控也照发。
   * 发送水位设成 1：发送队列空着就算到了水位，后面的中断测试用 */
  REG(PADSEL) = F_BUS;
  REG(UART1 + UART_DIV) = 99;
  REG(UART1 + UART_TXCTRL) = 1 | 1 << 4 | 1 << 16;
  REG(UART1 + UART_RXCTRL) = 1;
  bad = 0, got = 0;
  for (int i = 0; i < 4; i++) {
    uint32_t c = 0x5a + 0x21 * i, r;
    REG(UART1 + UART_TXDATA) = c;
    UNTIL(!((r = REG(UART1 + UART_RXDATA)) >> 31), 20000);
    bad |= (r & 0x800000ff) != (c & 0xff);
    got = got << 8 | (r & 0xff);
  }
  verdict("uart", bad, got);
  irq(UART1_IRQ);
  REG(UART1 + UART_IE) = 1;
  bad = UNTIL(STATE[COUNT], 20000);
  verdict("uirq", bad || STATE[CLAIM] != UART1_IRQ, STATE[CLAIM]);

  /* 单总线：发复位，线上那个器件应一个存在脉冲 */
  REG(ONEW0 + ONEW_TICK) = hz / 1000000 - 1;
  REG(ONEW0 + ONEW_STATUS) = 4;
  REG(ONEW0 + ONEW_CMD) = 0;
  bad = UNTIL(REG(ONEW0 + ONEW_STATUS) & 4, 20000);
  got = REG(ONEW0 + ONEW_STATUS);
  verdict("onew", bad || !(got & 2), got & 6);

  /* PS/2：线上那个设备每 3 毫秒送一次 0x1C。开在一帧中间的那一次会报错，清掉再等一帧 */
  REG(PS2 + PS2_TICK) = hz / 1000000 - 1;
  REG(PS2 + PS2_CTRL) = 1;
  bad = 1, got = 0;
  for (int i = 0; i < 3 && bad; i++) {
    REG(PS2 + PS2_STATUS) = 3;
    UNTIL(REG(PS2 + PS2_STATUS) & 3, 40000);
    got = REG(PS2 + PS2_STATUS) << 8 | REG(PS2 + PS2_RXD);
    bad = (got & 0x3ff) != 0x11c;
  }
  REG(PS2 + PS2_CTRL) = 0;
  verdict("ps2", bad, got & 0x3ff);

  /* I2C：板上 0x50 有一个从设备，读它得 0xA5；0x51 没人应。SCL 设在 1 MHz（一位切五份） */
  REG(I2C0 + I2C_PRESC) = hz / 5000000 - 1;
  REG(I2C0 + I2C_CTRL) = 0x80;
  REG(I2C0 + I2C_TXDATA) = 0xa1;
  REG(I2C0 + I2C_CMD) = 0x90;
  bad = UNTIL(!(REG(I2C0 + I2C_STATUS) & 2), 20000);
  got = REG(I2C0 + I2C_STATUS) >> 7 & 1;
  /* 读一个字节，不应答，停止 */
  REG(I2C0 + I2C_CMD) = 0x68;
  bad |= UNTIL(!(REG(I2C0 + I2C_STATUS) & 0x42), 20000);
  got = got << 8 | (REG(I2C0 + I2C_RXDATA) & 0xff);
  REG(I2C0 + I2C_TXDATA) = 0xa3;
  REG(I2C0 + I2C_CMD) = 0x90;
  bad |= UNTIL(!(REG(I2C0 + I2C_STATUS) & 2), 20000);
  got = got << 8 | (REG(I2C0 + I2C_STATUS) >> 7 & 1);
  REG(I2C0 + I2C_CMD) = 0x40;
  bad |= UNTIL(!(REG(I2C0 + I2C_STATUS) & 0x42), 20000);
  REG(I2C0 + I2C_CTRL) = 0;
  verdict("i2c", bad || got != 0x00a501, got);

  /* CAN：TX 在板上接回 RX，线上没有别的节点。发一帧，自己听得到自己，到应答位没人应，记的是应答错（3）。
   * 哪一根没接上，头一个显性位就读不回来，记的是位错（5） */
  REG(CAN0 + CAN_EVENTS) = 0x7f;
  REG(CAN0 + CAN_CTRL) = 1;
  bad = UNTIL(REG(CAN0 + CAN_STATUS) & 8, 20000);
  REG(CAN0 + CAN_TXID) = 0x123 << 18;
  REG(CAN0 + CAN_TXDLC) = 0;
  REG(CAN0 + CAN_CMD) = 1;
  bad |= UNTIL(REG(CAN0 + CAN_EVENTS) & 4, 20000);
  got = REG(CAN0 + CAN_STATUS) >> 4 & 15;
  REG(CAN0 + CAN_CMD) = 2;
  REG(CAN0 + CAN_CTRL) = 0;
  REG(CAN0 + CAN_TXID) = 0;
  verdict("can", bad || got != 3, got);

  /* 计时器的捕获脚：板上接着串口 1 的 TXD。发一个 0，停止位的上升沿把计数器抓进去；
   * 抓完把计数器清掉，后面的比较测试从 0 数起 */
  REG(TIMER0 + TIMER_CTRL) = 1;
  got = REG(TIMER0 + TIMER_CAPT);
  REG(UART1 + UART_TXDATA) = 0;
  bad = UNTIL(!(REG(UART1 + UART_RXDATA) >> 31), 20000);
  bad |= REG(TIMER0 + TIMER_CAPT) <= got;
  got = REG(TIMER0 + TIMER_CAPT) > got;
  REG(TIMER0 + TIMER_CTRL) = 2;
  REG(TIMER0 + TIMER_CTRL) = 0;
  verdict("capt", bad, got);

  /* PWM 的四根脚与看门狗的复位出：这五根选到第 2 组，x0 至 x4 留作 GPIO 的输入，板上一对一接过来看。
   * 占空比只有满与零，四路逐路单独拉高，读到的依次是 1、2、4、8（两路接反了也看得出）；
   * 看门狗数完 200 拍，复位出拉高，关掉就落下 */
  REG(GPIO1 + GPIO_DIR) = 0;
  REG(PADSEL) = 0xaa8000;
  REG(PWM0 + PWM_PERIOD) = 7;
  REG(PWM0 + PWM_CTRL) = 5;
  got = 0;
  for (uint32_t k = 0; k < 4; k++) {
    for (uint32_t j = 0; j < 4; j++) REG(PWM0 + PWM_DUTY + 4 * j) = j == k ? 8 : 0;
    got = got << 4 | (REG(GPIO1 + GPIO_DIN) & 0x1f);
  }
  REG(PWM0 + PWM_CTRL) = 0;
  REG(WDT0 + WDT_LOAD) = 200;
  REG(WDT0 + WDT_CTRL) = 3;
  bad = UNTIL(REG(GPIO1 + GPIO_DIN) & 0x10, 20000);
  got = got << 8 | (REG(GPIO1 + GPIO_DIN) & 0x1f);
  REG(WDT0 + WDT_CTRL) = 0;
  got = got << 8 | (REG(GPIO1 + GPIO_DIN) & 0x1f);
  /* 喂一次把「到期」那个记号清掉，否则它留着当中断挂在 PLIC 上 */
  REG(WDT0 + WDT_FEED) = 0xa5a55a5a;
  for (uint32_t k = 0; k < 4; k++) REG(PWM0 + PWM_DUTY + 4 * k) = 0;
  REG(PWM0 + PWM_PERIOD) = 0;
  REG(WDT0 + WDT_LOAD) = 0;
  verdict("pins", bad || got != 0x12481000, got);

#if ETH
  /* 以太网：RMII 的发送在板上接回接收。发一帧广播，从接收半区读回来，长度是补齐到 60 再加 4 字节 FCS */
  REG(PADSEL) = F_NET;
  REG(EMAC0 + EMAC_MACLO) = 0x56789abc;
  REG(EMAC0 + EMAC_MACHI) = 0x1234;
  REG(EMAC0 + EMAC_CTRL) = 1;
  /* 目的地址全 1，源地址 12:34:56:78:9a:bc，后面是类型与两个字的数据；帧缓冲区的前一半发、后一半收 */
  static const uint32_t frame[] = {0xffffffff, 0x3412ffff, 0xbc9a7856, 0xa5a50008, 0x0a0b0c0d};
  for (uint32_t k = 0; k < 5; k++) REG(EMAC0 + EMAC_FRAME + 4 * k) = frame[k];
  REG(EMAC0 + EMAC_TXLEN) = 20;
  bad = UNTIL(REG(EMAC0 + EMAC_STATUS) & 2, 20000);
  for (uint32_t k = 0; k < 5; k++) bad |= REG(EMAC0 + EMAC_FRAME + EMAC_RX + 4 * k) != frame[k];
  got = REG(EMAC0 + EMAC_STATUS) << 16 | REG(EMAC0 + EMAC_RXLEN);
  REG(EMAC0 + EMAC_CTRL) = 0;
  verdict("emac", bad || (got & 0xfff) != 64, got);
#else
  /* 没有以太网：寄存器页与帧缓冲区页都空着，PLIC 的 23 号不会响 */
  REG(EMAC0 + EMAC_CTRL) = 1;
  REG(EMAC0 + EMAC_FRAME) = 0x12345678;
  got = REG(EMAC0 + EMAC_CTRL) | REG(EMAC0 + EMAC_FRAME) | REG(EMAC0 + EMAC_STATUS);
  verdict("emac", got != 0, got);
#endif

  /* SPI：板上的回声从设备每个字节回上一个字节的反码，头一个回 0xFF。片选在四个字节之间一直按着 */
  REG(PADSEL) = F_SPI;
  REG(SPI2 + SPI_SCKDIV) = 3;
  REG(SPI2 + SPI_CSID) = 0;
  REG(SPI2 + SPI_CSMODE) = 2;
  bad = 0, got = 0;
  for (int i = 0; i < 4; i++) {
    uint32_t r;
    REG(SPI2 + SPI_TXDATA) = 0x12 + 0x22 * i;
    bad |= UNTIL(!((r = REG(SPI2 + SPI_RXDATA)) >> 31), 20000);
    got = got << 8 | (r & 0xff);
  }
  REG(SPI2 + SPI_CSMODE) = 0;
  verdict("spi", bad || got != 0xffedcba9, got);

  /* SPI 的第二根片选：板上的从设备被它选中时回原码，不取反 */
  REG(SPI2 + SPI_CSID) = 1;
  REG(SPI2 + SPI_CSMODE) = 2;
  bad = 0, got = 0;
  for (int i = 0; i < 2; i++) {
    uint32_t r;
    REG(SPI2 + SPI_TXDATA) = 0x3c + 0x47 * i;
    bad |= UNTIL(!((r = REG(SPI2 + SPI_RXDATA)) >> 31), 20000);
    got = got << 8 | (r & 0xff);
  }
  REG(SPI2 + SPI_CSMODE) = 0;
  REG(SPI2 + SPI_CSID) = 0;
  verdict("spics1", bad || got != 0xff3c, got);

  /* 随机数：噪声脚在板上接着一个伪随机的码流。开起来，启动自检要过、要出得来数；
   * 脚没接上的话是一串不变的电平，重复计数那一项当场不过 */
  REG(RNG0 + RNG_CTRL) = 1;
  bad = UNTIL(REG(RNG0 + RNG_STATUS) & 1, 40000);
  got = REG(RNG0 + RNG_STATUS) & 0xf;
  REG(RNG0 + RNG_CTRL) = 0;
  verdict("rng", bad || got != 3, got);

  /* I2S：SD 出在板上接回入，发一帧左右声道，收回来的要是同两个数 */
  REG(I2S0 + I2S_DIV) = 3;
  REG(I2S0 + I2S_TXL) = 0x1234;
  REG(I2S0 + I2S_TXR) = 0xabcd;
  REG(I2S0 + I2S_CTRL) = 1 | 16 << 8;
  bad = 0;
  for (int i = 0; i < 3; i++) {
    REG(I2S0 + I2S_STATUS) = 1;
    bad |= UNTIL(REG(I2S0 + I2S_STATUS) & 1, 20000);
  }
  got = REG(I2S0 + I2S_RXL) << 16 | (REG(I2S0 + I2S_RXR) & 0xffff);
  REG(I2S0 + I2S_CTRL) = 0;
  verdict("i2s", bad || got != 0x1234abcd, got);

  /* SerDes：先在片内自环（收端听自己的发端），四个字节原样回来；收到字节的中断经 PLIC 的 27 号进来 */
  irq(SD_IRQ);
  bad = REG(SD) != 0x53524431;
  REG(SD + SD_CTRL) = SD_EN | SD_LOOP | SD_IE;
  bad |= UNTIL(REG(SD + SD_STAT) & 2, 20000);
  for (int i = 0; i < 4; i++) REG(SD + SD_TX) = 0x21 + 0x33 * i;
  got = 0;
  for (int i = 0; i < 4; i++) {
    bad |= UNTIL(REG(SD + SD_STAT) & 8, 20000);
    got = got << 8 | (REG(SD + SD_RX) & 0x3ff);
  }
  verdict("sdloop", bad || got != 0x215487ba, got);
  verdict("sdirq", !STATE[COUNT] || STATE[CLAIM] != SD_IRQ, STATE[CLAIM]);

  /* 再经焊盘：x4 出、x5 回，板上连着。PRBS 跑一阵零误码；线上翻一位，记到错 */
  REG(SD + SD_CTRL) = SD_EN | SD_PTX | SD_PRX;
  bad = UNTIL(REG(SD + SD_STAT) & 2, 20000);
  for (volatile uint32_t i = 0; i < 300; i++) {}
  REG(SD + SD_CMD) = 4;
  bad |= UNTIL(!(REG(SD + SD_STAT) & 0x20), 20000);
  got = REG(SD + SD_NPERR);
  verdict("sdpad", bad || REG(SD + SD_NPBYTE) < 64 || got, got);
  REG(SD + SD_CMD) = 1;
  for (volatile uint32_t i = 0; i < 100; i++) {}
  REG(SD + SD_CMD) = 4;
  bad = UNTIL(!(REG(SD + SD_STAT) & 0x20), 20000);
  got = REG(SD + SD_NPERR);
  verdict("sderr", bad || !got, !!got);
  REG(SD + SD_CTRL) = 0;
  REG(PADSEL) = F_GPIO;

  /* 数字式 ADC 与 DAC：六根脚接管 GPIO 的第 6 至 11 位。板上第 0 路 ADC 量一个四分之一满幅的直流，
   * 第 1 路量第 0 路 DAC 的码流（设在八分之三满幅）。窗口 1024 个节拍，头一个是半截的、取第二个；
   * 读数除以 16 取整，该是 16 与 24 */
  {
    uint32_t a0 = 0, a1 = 0;
    REG(GPIO1 + GPIO_DIR) = 0;
    bad = REG(SDM) != 0x53444d31;
    REG(SDM + SDM_PRE) = 0;
    REG(SDM + SDM_WIN) = 10;
    REG(SDM + SDM_DAC0) = 0x6000;
    REG(SDM + SDM_CTRL) = 0x100 | 0xd;
    for (int k = 0; k < 2; k++) {
      bad |= UNTIL((a0 = REG(SDM + SDM_ADC0)) >> 31, 20000);
      bad |= UNTIL((a1 = REG(SDM + SDM_ADC1)) >> 31, 20000);
    }
    got = ((a0 & 0x1ffff) + 8) >> 4 << 16 | ((a1 & 0x1ffff) + 8) >> 4;
    REG(SDM + SDM_CTRL) = 0;
    verdict("sdm", bad || got != 0x00100018, got);
  }

  /* 时钟控制：Frame 形态里没有 PLL，寄存器照样在。复位值是旁路、N 32、OD 8 分频；写进去的读得回来；量到的频率是 0 */
  bad = REG(CLK) != 0x434c4b31 || REG(CLK + 4) != 0x00010620;
  REG(CLK + 4) = 0x00010428;
  bad |= REG(CLK + 4) != 0x00010428 || (REG(CLK + 0xc) & 0xffffff) != 0;
  REG(CLK + 4) = 0x00010620;
  verdict("clk", bad, REG(CLK));

  /* 计时器：数到比较值，经 PLIC 的 13 号进来 */
  irq(TIMER0_IRQ);
  REG(TIMER0 + TIMER_CMP) = 2000;
  REG(TIMER0 + TIMER_ISTA) = 0xff;
  REG(TIMER0 + TIMER_IEN) = 1;
  REG(TIMER0 + TIMER_CTRL) = 1;
  bad = UNTIL(STATE[COUNT], 20000);
  got = REG(TIMER0 + TIMER_ISTA);
  REG(TIMER0 + TIMER_CTRL) = 0;
  verdict("tirq", bad || STATE[CLAIM] != TIMER0_IRQ || !(got & 1), STATE[CLAIM]);

  /* CRC：复位后的模型是 CRC-8/MAXIM-DOW，"123456789" 的校验值是 0xA1 */
  REG(CRC0 + CRC_CTRL) = 1;
  for (const char *p = "123456789"; *p; p++) REG(CRC0 + CRC_DATA) = *p;
  got = REG(CRC0 + CRC_RESULT);
  verdict("crc", got != 0xa1, got);

  say("done\n");
  for (;;) {}
}
