/* 数字式 DAC 与 ADC：DAC0 出 435 Hz 的正弦，DAC1 出一秒一个的锯齿；ADC0 量一个电压，每半秒从串口报一次毫伏数。
 * 开头先自检一次：DAC0 停在八分之三满幅，ADC1 量它的码流，两路的读数（除以 64 取整）一起报出来。
 * 接线：x6 DAC0、x7 DAC1 各经 1 kΩ、100 nF 滤成电压；x8 是 ADC0 的反馈、x9 是它的输入，被测电压与反馈脚各经
 * 10 kΩ 汇到输入脚上的 10 nF；x10、x11 是 ADC1 的反馈与输入，自检时它的「被测电压」接 x6。
 * 码流 5 MHz，窗口 4096 个节拍：读数 0 至 4096 对 0 至 3.3 V，每秒 1220 个读数 */
#include "av.h"
#include "gpio.h"

enum { SDM_CTRL = 0x04, SDM_DAC0 = 0x08, SDM_DAC1 = 0x0c, SDM_ADC0 = 0x10, SDM_ADC1 = 0x14, SDM_WIN = 0x18, SDM_PRE = 0x1c };

static const int16_t sine[23] = {0,     4455,  8579,   12067,  14658,  16160,  16461,  15540,
                                 13464, 10388, 6540,   2206,   -2206,  -6540,  -10388, -13464,
                                 -15540, -16461, -16160, -14658, -12067, -8579, -4455};

/* 等这一路出一个新读数。头一个窗口是半截的，调用的人自己扔掉 */
static uint32_t adc(uint32_t reg) {
  uint32_t v;
  while (!((v = REG(SDM + reg)) >> 31)) {}
  return v & 0x1ffff;
}

void main(void) {
  say("to2610 sdm\n");
  REG(GPIO1 + GPIO_DIR) = 0;
  REG(SDM + SDM_PRE) = 9;
  REG(SDM + SDM_WIN) = 12;
  REG(SDM + SDM_DAC0) = 0x6000;
  REG(SDM + SDM_DAC1) = 0;
  REG(SDM + SDM_CTRL) = 0x100 | 0xf;
  adc(SDM_ADC0);
  adc(SDM_ADC1);
  uint32_t a0 = adc(SDM_ADC0), a1 = adc(SDM_ADC1);
  say("self ");
  hex((a0 + 32) >> 6 << 16 | (a1 + 32) >> 6);
  putch('\n');

  uint32_t next = MTIME, report = next, i = 0;
  for (;;) {
    /* 每 100 微秒换一个点，23 个点一圈 */
    while ((int32_t)(MTIME - next) < 0) {}
    next += 100;
    REG(SDM + SDM_DAC0) = 0x8000 + sine[i];
    i = i == 22 ? 0 : i + 1;
    REG(SDM + SDM_DAC1) = MTIME >> 4 & 0xffff;
    if ((int32_t)(MTIME - report) >= 0) {
      report += 500 * MS;
      say("adc0 mv ");
      hex((REG(SDM + SDM_ADC0) & 0x1ffff) * 3300 >> 12);
      putch('\n');
    }
  }
}
