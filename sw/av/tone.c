/* I2S 放音与录音：先放一段 1 kHz 的正弦，再把收到的原样放出去（麦克风直通到喇叭），两段轮着来。
 * 每段末尾从串口报这一段里收到的峰值，与平均一帧用了多少微秒。
 * 接线：x7 SCK、x8 WS 同时给功放（MAX98357A 一类）与麦克风（INMP441 一类），x9 SD 出给功放，x10 SD 入接麦克风。
 * 一帧左右各 32 位，64 个 SCK：麦克风要这个数。采样率 = 主频 /（128 ×（DIV + 1）），50 MHz 下 DIV 23 是 16276 Hz */
#include "av.h"
#include "i2s.h"

#ifndef FRAMES
#define FRAMES 32768
#endif

static const int16_t sine[16] = {0,      6270,  11585,  15137,  16384,  15137,  11585,  6270,
                                 0,      -6270, -11585, -15137, -16384, -15137, -11585, -6270};

void main(void) {
  say("to2610 tone\n");
  REG(PADSEL) = PAD(7, 3) | PAD(8, 3) | PAD(9, 3) | PAD(10, 3);
  REG(I2S0 + I2S_DIV) = 23;
  REG(I2S0 + I2S_TXL) = 0;
  REG(I2S0 + I2S_TXR) = 0;
  REG(I2S0 + I2S_CTRL) = 1 | 32 << 8;
  for (uint32_t round = 0;; round++) {
    uint32_t thru = round & 1, peak = 0, t0;
    /* 头一帧可能是半截的，等过它再计时 */
    REG(I2S0 + I2S_STATUS) = 1;
    while (!(REG(I2S0 + I2S_STATUS) & 1)) {}
    t0 = MTIME;
    for (uint32_t n = 0; n < FRAMES; n++) {
      REG(I2S0 + I2S_STATUS) = 1;
      while (!(REG(I2S0 + I2S_STATUS) & 1)) {}
      int32_t in = (int32_t)REG(I2S0 + I2S_RXL);
      uint32_t mag = in < 0 ? -(uint32_t)in : (uint32_t)in;
      if (mag > peak) peak = mag;
      uint32_t out = thru ? (uint32_t)in : (uint32_t)sine[n & 15] << 16;
      REG(I2S0 + I2S_TXL) = out;
      REG(I2S0 + I2S_TXR) = out;
    }
    t0 = MTIME - t0;
    say(thru ? "thru peak " : "tone peak ");
    hex(peak);
    say(" us ");
    hex(t0 / FRAMES);
    putch('\n');
  }
}
