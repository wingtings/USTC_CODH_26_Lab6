# RISC-V M-Extension RV32M 测试代码
.text
.globl _start

_start:
    # --- 1. 乘法基础测试 (mul) ---
    # 计算 50 * 40，取低 32 位
    li t0, 50
    li t1, 40
    mul t2, t0, t1      # 预期 t2 = 2000 (0x000007D0)

    # --- 2. 有符号高位乘法 (mulh) ---
    # 计算 -2147483648 * 2
    li t0, 0x80000000   # INT_MIN
    li t1, 2
    mulh t3, t0, t1     # 预期 t3 = -1 (0xFFFFFFFF)
    mul t4, t0, t1      # 预期 t4 = 0 (0x00000000) (合在一起表示 -4294967296)

    # --- 3. 无符号高位乘法 (mulhu) ---
    # 计算 (2^32-1) * (2^32-1)
    li t0, 0xFFFFFFFF   # 4294967295
    li t1, 0xFFFFFFFF
    mulhu t5, t0, t1    # 预期 t5 = 0xFFFFFFFE (低位为 0x00000001)
    
    # --- 4. 有符号-无符号高位乘法 (mulhsu) ---
    # 计算 -2 (有符号) * 5 (无符号) = -10
    li t0, -2           # 0xFFFFFFFE
    li t1, 5
    mulhsu t6, t0, t1   # 预期 t6 = -1 (0xFFFFFFFF)，低位是 0xFFFFFFF6

    # --- 5. 有符号除法 (div) 和取模 (rem) ---
    # 计算 100 / -3 和 100 % -3
    li t0, 100
    li t1, -3
    div a0, t0, t1      # 预期 a0 = -33 (0xFFFFFFDF)
    rem a1, t0, t1      # 预期 a1 = 1 (取模结果符号与被除数相同)

    # --- 6. 无符号除法 (divu) 和取模 (remu) ---
    # 计算 4294967196 / 3 和 4294967196 % 3
    li t0, -100         # 无符号看作 0xFFFFFF9C (4294967196)
    li t1, 3
    divu a2, t0, t1     # 预期 a2 = 1431655732 (0x55555534)
    remu a3, t0, t1     # 预期 a3 = 0

    # --- 7. 边界情况：除以零测试 ---
    li t0, 50
    li t1, 0
    div a4, t0, t1      # 有符号除零：预期 a4 = -1 (0xFFFFFFFF)
    divu a5, t0, t1     # 无符号除零：预期 a5 = 2^32-1 (0xFFFFFFFF)
    rem a6, t0, t1      # 有符号对零取模：预期 a6 = 被除数 (50 / 0x32)
    remu a7, t0, t1     # 无符号对零取模：预期 a7 = 被除数 (50 / 0x32)

    # --- 8. 边界情况：除法溢出测试 ---
    # RISC-V 规范中，唯一发生除法溢出的情况是 INT_MIN / -1
    li t0, 0x80000000   # -2147483648
    li t1, -1
    div s0, t0, t1      # 溢出处理：预期 s0 = 被除数 (0x80000000)
    rem s1, t0, t1      # 溢出处理：预期 s1 = 0

    # 测试结束，进入死循环
end:
    j end