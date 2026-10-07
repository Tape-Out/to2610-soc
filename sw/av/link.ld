OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY { ram (rwx) : ORIGIN = 0x80000000, LENGTH = 1M }
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) *(.data*) *(.sdata*) } > ram
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame) }
}
