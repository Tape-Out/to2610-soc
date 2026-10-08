# to2610-soc

A Linux system chip with the catalogue's peripherals, for the ECOS 2610 shuttle: the KianV RV32IMA Sv32 SoC of [`to2610-kvc`](https://github.com/Tape-Out/to2610-kvc) with a window of its address map opened onto fifteen peripherals assembled from the organisation's IP library.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20OR%20MulanPSL--2.0-blue)

The SoC is upstream's, its submodule untouched, taken from [`gf180mcu-kianv-rv32ima-sv32`](https://github.com/Tape-Out/gf180mcu-kianv-rv32ima-sv32). What this repository adds:

| File | What |
|:--:|:--:|
| `patch/soc.patch` | opens `0x4000_0000` to `0x4FFF_FFFF` in upstream's `soc.v` and brings the bus and 21 interrupt lines out of `chip_core` |
| `hwsrc/kv_apb.v` | the KianV bus to APB4 |
| `soc-io/ip.yaml` | the peripheral block, an assembly manifest: `ran asic soc-io` turns it into one Verilog module with an APB4 slave port |
| `hwsrc/soc_core.v` | core, bridge and peripherals together, every pin a port; shared by both forms of the chip |
| `hwsrc/soc_frame.v` | the frame form: the 54 pads of `to2610-kvc` in place, twelve more multiplexed four ways |
| `hwsrc/sysctl.v` | identification and the pad selection register |

The functions, the address map, the pad table, the chip tests and the limits are in [`docs/流片说明.md`](docs/流片说明.md); the tape-out report is generated from that file.

## The window

| Address | Peripheral | PLIC source |
|:--:|:--:|:--:|
| `0x4000_0000` | `uart`, with flow control | 11 |
| `0x4000_1000` | `gpio`, 16 pins | 12 |
| `0x4000_2000` | `timer` | 13 |
| `0x4000_3000` | `wdt` | 14 |
| `0x4000_4000` | `rtc` | 15 |
| `0x4000_5000` | `i2c` | 16 |
| `0x4000_6000` | `spi` | 17 |
| `0x4000_7000` | `onew` | 18 |
| `0x4000_8000` | `i2s` | 19 |
| `0x4000_9000` | `can` | 20 |
| `0x4000_A000` | `ps2` | 21 |
| `0x4000_B000` | `rng` | 22 |
| `0x4000_C000` | `emac`, two pages; the MPW form only | 23 |
| `0x4000_E000` | `pwm` | |
| `0x4000_F000` | `crc` | |
| `0x4001_0000` | `serdes_apb`, one lane of [`serdes`](https://github.com/Tape-Out/serdes) | 27 |
| `0x4002_0000` | `sdm`, two sigma-delta DACs and two sigma-delta ADCs on six GPIO pins | |
| `0x4005_0000` | `clkctl`, the PLL settings, a divider, the line clock switch and a frequency meter | |
| `0x4003_0000` | `sysctl` | |

Each peripheral's registers are in its own repository's `regmap.yaml`; `ran gen <name>` writes the C header.

## Testing and tape-out

```console
$ ran run to2610-soc src                  # assemble build/src
$ ran test to2610-soc                     # the chip tests, on the Verilog file that goes to the shuttle
$ ran asic to2610-soc                     # to2610_soc.v, ecc at 50 MHz, report.json
```

The chip tests run on Verilator with pin-level models of the SDRAM, the flash and the UART: four tests of `to2610-kvc` unchanged, then `htest/xio`, a bare-metal program that reaches every peripheral through the window, drives seven of them through the multiplexed pads against loopbacks and small models of the parts on the board, and takes three interrupts through the PLIC.

## License

任选其一：

- [MIT](LICENSE-MIT)
- [Apache 2.0](LICENSE-APACHE)
- [木兰宽松许可证 第2版](LICENSE-MULAN)

`SPDX-License-Identifier: MIT OR Apache-2.0 OR MulanPSL-2.0`

The upstream sources keep their own licence: Apache-2.0.

除非另行说明，你提交的贡献按上述三者同时授权，不附加其他条件。
