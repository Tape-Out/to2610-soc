# 放音录音（tone）与数字式 DAC、ADC（sdm）两个小程序，由引导程序搬进 SDRAM 再跑：
#   make -C sw/av INC=<头文件目录>        头文件用 ran gen i2s、ran gen gpio 出
#   make -C sw/av INC=... SIM=1           仿真用：等待缩到千分之一、每轮只放 64 帧
O ?= build
CROSS ?= riscv64-unknown-elf-
INC ?= $(O)/inc
CFLAGS = -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -I$(INC)
ifeq ($(SIM),1)
CFLAGS += -DSIM -DFRAMES=64
endif

all: $(O)/tone.bin $(O)/sdm.bin

$(O)/%.bin: start.S %.c av.h link.ld
	mkdir -p $(O)
	$(CROSS)gcc $(CFLAGS) -Wl,-T,link.ld -o $(O)/$*.elf start.S $*.c
	$(CROSS)objcopy -O binary $(O)/$*.elf $@

.PHONY: all
