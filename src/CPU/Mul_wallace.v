`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Mul_wallace  (33x33 有符号华莱士树乘法器)
// Description: 用 CSA 华莱士树实现 33x33 -> 66 位有符号乘法，组合单周期，满足
//   "至多 5 周期、禁用循环加法、禁用 IP 核与 * / % 运算符" 的要求。
//
//   接口约定（与 EX 阶段配合）：
//     - mulhu : 调用方把 32 位操作数零扩展到 33 位（最高位补 0）。
//     - mul/mulh: 调用方把 32 位操作数符号扩展到 33 位。
//     于是统一按一次 33x33 有符号乘法即可覆盖 mul / mulh / mulhu。
//
//   原理：a, b 均为 33 位有符号数。把 a 符号扩展到 66 位 aext，
//     a*b = Σ_{i=0..31} b[i]·(aext<<i)  −  b[32]·(aext<<32)
//     共 33 个部分积（第 32 个为负权重，取两补数）。
//
//   华莱士树：每级用 CSA 把 3 个数压成 2 个（sum 与 carry）。
//     关键点：CSA 的 carry 权重为 2，送入下一级前必须左移一位（{carry,1'b0}）。
//     部分积数量 33→22→15→10→7→5→4→3→2，最后用一个真正的加法器(CPA)求和。
//////////////////////////////////////////////////////////////////////////////////

module Mul_wallace(
    input  wire [32:0] a,
    input  wire [32:0] b,
    output wire [65:0] res
);
    // 被乘数符号扩展到 66 位
    wire [65:0] aext = {{33{a[32]}}, a};

    // ---------------- 生成 33 个部分积 ----------------
    wire [65:0] pp [0:32];
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : gen_pp
            assign pp[i] = b[i] ? (aext << i) : 66'd0;        // 低 32 位正权重
        end
    endgenerate
    // 第 32 位（符号位）为负权重：-(aext<<32) = 两补数
    assign pp[32] = b[32] ? (~(aext << 32) + 66'd1) : 66'd0;

    // ---------------- 华莱士树逐级压缩 ----------------
    // 每级数组：l0=33, l1=22, l2=15, l3=10, l4=7, l5=5, l6=4, l7=3, l8=2
    wire [65:0] l0 [0:32];
    wire [65:0] l1 [0:21];
    wire [65:0] l2 [0:14];
    wire [65:0] l3 [0:9];
    wire [65:0] l4 [0:6];
    wire [65:0] l5 [0:4];
    wire [65:0] l6 [0:3];
    wire [65:0] l7 [0:2];
    wire [65:0] l8 [0:1];

    generate
        for (i = 0; i < 33; i = i + 1) begin : gen_l0
            assign l0[i] = pp[i];
        end
    endgenerate

    genvar g;

    // L0: 33 -> 22   (11 个 CSA, 0 余)
    generate
        for (g = 0; g < 11; g = g + 1) begin : L0
            wire [65:0] s, cy;
            CSA #(66) u(.a(l0[3*g]), .b(l0[3*g+1]), .c(l0[3*g+2]), .sum(s), .carry(cy));
            assign l1[2*g]   = s;
            assign l1[2*g+1] = {cy[64:0], 1'b0};   // carry 左移一位
        end
    endgenerate

    // L1: 22 -> 15   (7 个 CSA, 余 1)
    generate
        for (g = 0; g < 7; g = g + 1) begin : L1
            wire [65:0] s, cy;
            CSA #(66) u(.a(l1[3*g]), .b(l1[3*g+1]), .c(l1[3*g+2]), .sum(s), .carry(cy));
            assign l2[2*g]   = s;
            assign l2[2*g+1] = {cy[64:0], 1'b0};
        end
    endgenerate
    assign l2[14] = l1[21];

    // L2: 15 -> 10   (5 个 CSA, 0 余)
    generate
        for (g = 0; g < 5; g = g + 1) begin : L2
            wire [65:0] s, cy;
            CSA #(66) u(.a(l2[3*g]), .b(l2[3*g+1]), .c(l2[3*g+2]), .sum(s), .carry(cy));
            assign l3[2*g]   = s;
            assign l3[2*g+1] = {cy[64:0], 1'b0};
        end
    endgenerate

    // L3: 10 -> 7    (3 个 CSA, 余 1)
    generate
        for (g = 0; g < 3; g = g + 1) begin : L3
            wire [65:0] s, cy;
            CSA #(66) u(.a(l3[3*g]), .b(l3[3*g+1]), .c(l3[3*g+2]), .sum(s), .carry(cy));
            assign l4[2*g]   = s;
            assign l4[2*g+1] = {cy[64:0], 1'b0};
        end
    endgenerate
    assign l4[6] = l3[9];

    // L4: 7 -> 5     (2 个 CSA, 余 1)
    generate
        for (g = 0; g < 2; g = g + 1) begin : L4
            wire [65:0] s, cy;
            CSA #(66) u(.a(l4[3*g]), .b(l4[3*g+1]), .c(l4[3*g+2]), .sum(s), .carry(cy));
            assign l5[2*g]   = s;
            assign l5[2*g+1] = {cy[64:0], 1'b0};
        end
    endgenerate
    assign l5[4] = l4[6];

    // L5: 5 -> 4     (1 个 CSA, 余 2)
    wire [65:0] s5, cy5;
    CSA #(66) u5(.a(l5[0]), .b(l5[1]), .c(l5[2]), .sum(s5), .carry(cy5));
    assign l6[0] = s5;
    assign l6[1] = {cy5[64:0], 1'b0};
    assign l6[2] = l5[3];
    assign l6[3] = l5[4];

    // L6: 4 -> 3     (1 个 CSA, 余 1)
    wire [65:0] s6, cy6;
    CSA #(66) u6(.a(l6[0]), .b(l6[1]), .c(l6[2]), .sum(s6), .carry(cy6));
    assign l7[0] = s6;
    assign l7[1] = {cy6[64:0], 1'b0};
    assign l7[2] = l6[3];

    // L7: 3 -> 2     (1 个 CSA)
    wire [65:0] s7, cy7;
    CSA #(66) u7(.a(l7[0]), .b(l7[1]), .c(l7[2]), .sum(s7), .carry(cy7));
    assign l8[0] = s7;
    assign l8[1] = {cy7[64:0], 1'b0};

    // L8: 最后两个数用真正的加法器(CPA)相加
    assign res = l8[0] + l8[1];
endmodule
