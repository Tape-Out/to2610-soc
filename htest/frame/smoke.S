# mpc-frame 两个测试台用的程序：经地址窗读 sysctl 的标识寄存器，对了从串口发 S（0x53），不对发 X（0x58）
# expect: 53
.section .text
.global _start
_start:
    li t0, 0x1000000c
    li t1, 16
    sw t1, 0(t0)
    li t0, 0x40030000
    lw t2, 0(t0)
    li t3, 0x534f4331
    li t1, 0x53
    beq t2, t3, 1f
    li t1, 0x58
1:  li t0, 0x10000000
    sw t1, 0(t0)
2:  j 2b
