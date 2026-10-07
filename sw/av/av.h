/* 音视频几个小程序共用的：串口、计时、地址窗里各外设的位置。程序由引导程序搬进 SDRAM 再跑，串口的分频它已经设好 */
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)
/* 每微秒走一格，与主频无关 */
#define MTIME REG(0x0200bff8)

#define XIO 0x40000000u
#define PAGE(n) (XIO + 0x1000u * (n))
#define GPIO1 PAGE(1)
#define SPI2 PAGE(6)
#define I2S0 PAGE(8)
#define PWM0 PAGE(14)
#define SDM (XIO + 0x20000u)
#define PADSEL (XIO + 0x30004u)
/* 第 k 根复用焊盘选第 f 组 */
#define PAD(k, f) ((uint32_t)(f) << 2 * (k))

/* 仿真里把等待缩到千分之一，别的不变 */
#ifdef SIM
#define MS 1u
#else
#define MS 1000u
#endif

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

static void wait_ms(uint32_t ms) {
  uint32_t t = MTIME;
  while (MTIME - t < ms * MS) {}
}
