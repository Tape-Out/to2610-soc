#!/usr/bin/env python3
"""算 PADSEL：把要用的外设脚选到 12 根复用焊盘上。

每根焊盘四选一，表与 hwsrc/soc_frame.v 的相同；PADSEL 在 0x4003_0004，第 2k+1:2k 位管 x<k>，复位全 0（都是 GPIO）。

用法：padsel.py <功能>...        功能可以写全（uart1.txd），也可以只写外设名（uart1、rmii、pwm），那就是它的每一根
      padsel.py --list           打印整张表
两个功能要同一根焊盘时报出来，不出数。
"""
import sys

PADS = [
    ("gpio0", "uart1.txd", "rmii.txd0", "spi2.sck"),
    ("gpio1", "uart1.rxd", "rmii.txd1", "spi2.cs0"),
    ("gpio2", "uart1.rts", "rmii.tx_en", "spi2.mosi"),
    ("gpio3", "uart1.cts", "rmii.rxd0", "spi2.miso"),
    ("gpio4", "i2c.scl", "rmii.rxd1", "serdes.tx"),
    ("gpio5", "i2c.sda", "rmii.crs_dv", "serdes.rx"),
    ("gpio6", "onew", "rmii.rx_er", "spi2.cs1"),
    ("gpio7", "can.tx", "pwm.0", "i2s.sck"),
    ("gpio8", "can.rx", "pwm.1", "i2s.ws"),
    ("gpio9", "ps2.clk", "pwm.2", "i2s.sdo"),
    ("gpio10", "ps2.dat", "pwm.3", "i2s.sdi"),
    ("gpio11", "timer.cap0", "wdt.rst", "rng.noise"),
]

if sys.argv[1:] == ["--list"]:
    for k, row in enumerate(PADS):
        print(f"x{k:<3}" + "".join(f"{f or '-':<14}" for f in row))
    sys.exit()

pick = {}
for want in sys.argv[1:]:
    hits = [(k, sel) for k, row in enumerate(PADS) for sel, f in enumerate(row)
            if f and (f == want or f.split(".")[0] == want)]
    if not hits:
        sys.exit(f"没有 {want} 这个功能，--list 看整张表")
    for k, sel in hits:
        if k in pick and pick[k] != sel:
            sys.exit(f"x{k} 上 {PADS[k][pick[k]]} 与 {PADS[k][sel]} 只能选一个")
        pick[k] = sel

value = sum(sel << 2 * k for k, sel in pick.items())
for k, row in enumerate(PADS):
    print(f"x{k:<3}{row[pick.get(k, 0)]}")
print(f"PADSEL = {value:#010x}")
print(f"Linux 下：devmem 0x40030004 32 {value:#x}")
