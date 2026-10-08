O ?= build
CROSS ?= riscv64-unknown-elf-
# 启动代码与链接脚本取黑盒仓 hello 的那一份；寄存器的头文件由 chip.sh 让息壤照各 IP 的 regmap.yaml 生成到 $(INC)
HELLO ?= ../../../gf180mcu-kianv-rv32ima-sv32/htest/hello
INC ?= $(O)/inc
# MPW 形态带以太网：ETH=1
ETH ?= 0

$(O)/xio.bin: $(HELLO)/start.S xio.c $(HELLO)/link.ld
	mkdir -p $(O)
	$(CROSS)gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -DETH=$(ETH) -I$(INC) -Wl,-T,$(HELLO)/link.ld -o $(O)/xio.elf $(HELLO)/start.S xio.c
	$(CROSS)objcopy -O binary $(O)/xio.elf $@
