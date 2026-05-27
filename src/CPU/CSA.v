`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: CSA  (Carry-Save Adder / 3:2 压缩器)
// Description: 把三个数的和转化为两个数(sum + carry)，不传播进位，关键路径仅一级全加器。
//   - sum   = a ^ b ^ c              （按位无进位和）
//   - carry = (a&b)|(b&c)|(c&a)      （按位进位，权重为 2，调用方需左移一位再相加）
//   - 满足 a + b + c == sum + (carry << 1)。
//   华莱士树每一层用它把部分积数量按 2/3 缩减，是乘法器的基础组件。
//////////////////////////////////////////////////////////////////////////////////

module CSA #(
    parameter WIDTH = 66
)(
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire [WIDTH-1:0] c,
    output wire [WIDTH-1:0] sum,    // S   = a^b^c
    output wire [WIDTH-1:0] carry   // C   = ab|bc|ca （送下一级前需 << 1）
);
    assign sum   = a ^ b ^ c;
    assign carry = (a & b) | (b & c) | (c & a);
endmodule
