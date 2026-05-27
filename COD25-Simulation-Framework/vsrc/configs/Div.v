`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Div
// Description: 组合逻辑除法器，支持 RV32M 的 div/divu/rem/remu。
//   - 不使用 IP 核，不使用 * / % 运算符（只用 -、比较、移位、拼接）。
//   - 单周期组合电路：先取绝对值做 32 步恢复除法，再按符号还原。
//   - is_signed=1 用于 div/rem，=0 用于 divu/remu。
//   - 严格遵循 RISC-V 规范的特殊情形：
//       除零      : quotient = 全 1 (-1)，remainder = dividend
//       有符号溢出: dividend=0x80000000 且 divisor=0xFFFFFFFF 时，
//                   quotient = 0x80000000，remainder = 0（由通用路径自然得到）
//////////////////////////////////////////////////////////////////////////////////

module Div(
    input       [31:0]  a,          // 被除数 dividend
    input       [31:0]  b,          // 除数   divisor
    input               is_signed,  // 1: div/rem(有符号)  0: divu/remu(无符号)
    output      [31:0]  quotient,
    output      [31:0]  remainder
);
    wire sign_a = is_signed & a[31];
    wire sign_b = is_signed & b[31];

    // 取绝对值（无符号时即原值）
    wire [31:0] ua = sign_a ? (~a + 32'd1) : a;
    wire [31:0] ub = sign_b ? (~b + 32'd1) : b;

    // 32 步恢复除法（组合展开）
    integer i;
    reg [32:0] rem_tmp;   // 工作余数，33 位防止左移溢出
    reg [31:0] uq;        // 无符号商
    always @(*) begin
        rem_tmp = 33'd0;
        uq      = 32'd0;
        for (i = 31; i >= 0; i = i - 1) begin
            rem_tmp = {rem_tmp[31:0], ua[i]};       // 余数左移并移入被除数当前位
            if (rem_tmp >= {1'b0, ub}) begin
                rem_tmp = rem_tmp - {1'b0, ub};
                uq[i]   = 1'b1;
            end
        end
    end
    wire [31:0] ur = rem_tmp[31:0];  // 无符号余数

    // 按符号还原：商符号 = 被除数^除数；余数符号 = 被除数
    wire q_neg = sign_a ^ sign_b;
    wire r_neg = sign_a;
    wire [31:0] q_signed = q_neg ? (~uq + 32'd1) : uq;
    wire [31:0] r_signed = r_neg ? (~ur + 32'd1) : ur;

    // 除零特殊情形（有/无符号商均为全 1，余数为被除数）
    wire div_zero = (b == 32'd0);

    assign quotient  = div_zero ? 32'hFFFFFFFF : q_signed;
    assign remainder = div_zero ? a            : r_signed;
endmodule
