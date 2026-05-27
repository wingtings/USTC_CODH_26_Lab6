`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: Div  (Radix-2 移位除法器，多周期 + 状态机握手)
// Description: 按 PDF "Radix-2 移位除法器" 实现 div/divu/rem/remu，无 IP、无 / 与 %。
//   - 多周期：除法无法廉价组合化，故用状态机控制，与流水线 EX 段握手。
//   - 符号处理：开始前记录符号并把操作数转为绝对值；结束后按符号还原。
//   - 核心：恢复除法。把 |被除数| 放进移位寄存器 Q，余数累加器 R(33 位防溢出)。
//       每步：R = {R[31:0], Q[31]}（左移并移入被除数当前最高位）；
//             若 R >= |除数| 则 R -= |除数|，商位=1，否则商位=0；
//             Q 左移并在低位补入商位。32 步后 Q=|商|，R[31:0]=|余数|。
//   - RISC-V 特殊情形：
//       除零      : 商 = 全 1(-1)，余数 = 被除数
//       有符号溢出: 0x80000000/0xFFFFFFFF 由通用路径自然得到 商=0x80000000、余数=0
//
//   握手协议（与 CPU.v EX 段配合）：
//     req  : EX 段存在除法指令（电平，整个停顿期间保持高）。
//     done : 结果就绪（单周期高）。CPU 在 done 这一拍放行流水线并锁存结果。
//     en   : 流水线时钟使能(global_en && valid)，低时状态机暂停以保持同步。
//////////////////////////////////////////////////////////////////////////////////

module Div(
    input  wire        clk,
    input  wire        rst,
    input  wire        en,          // 流水线时钟使能
    input  wire        req,         // EX 段存在除法指令（电平）
    input  wire [31:0] a,           // 被除数 dividend
    input  wire [31:0] b,           // 除数   divisor
    input  wire        is_signed,   // 1: div/rem(有符号)  0: divu/remu(无符号)
    output wire        busy,        // 计算进行中
    output wire        done,        // 结果就绪（单周期）
    output wire [31:0] quotient,
    output wire [31:0] remainder
);
    localparam IDLE = 2'd0, CALC = 2'd1, DONE = 2'd2;

    reg [1:0]  state;
    reg [5:0]  cnt;        // 步数计数（0..31）

    reg [32:0] R;          // 余数累加器（33 位，防左移溢出）
    reg [31:0] Q;          // 商/被除数移位寄存器
    reg [31:0] ubr;        // |除数|
    reg        q_neg;      // 商符号 = 被除数^除数
    reg        r_neg;      // 余数符号 = 被除数
    reg        zero;       // 除零标志
    reg [31:0] dividend_r; // 原始被除数（除零时余数=被除数）

    // 启动时计算绝对值与符号（输入按 is_signed 决定是否取符号）
    wire sa = is_signed & a[31];
    wire sb = is_signed & b[31];
    wire [31:0] ua = sa ? (~a + 32'd1) : a;     // |被除数|
    wire [31:0] ub = sb ? (~b + 32'd1) : b;     // |除数|

    // 单步恢复除法（组合）
    wire [32:0] shifted_R = {R[31:0], Q[31]};            // 左移并移入被除数当前最高位
    wire        ge        = (shifted_R >= {1'b0, ubr});  // 试商：余数是否够减
    wire [32:0] R_step    = ge ? (shifted_R - {1'b0, ubr}) : shifted_R;
    wire [31:0] Q_step    = {Q[30:0], ge};               // 低位补入商位

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; cnt <= 6'd0;
            R <= 33'd0; Q <= 32'd0; ubr <= 32'd0;
            q_neg <= 1'b0; r_neg <= 1'b0; zero <= 1'b0; dividend_r <= 32'd0;
        end else if (en) begin
            case (state)
                IDLE: begin
                    if (req) begin
                        R          <= 33'd0;
                        Q          <= ua;
                        ubr        <= ub;
                        q_neg      <= sa ^ sb;
                        r_neg      <= sa;
                        zero       <= (b == 32'd0);
                        dividend_r <= a;
                        cnt        <= 6'd0;
                        state      <= CALC;
                    end
                end
                CALC: begin
                    R   <= R_step;
                    Q   <= Q_step;
                    cnt <= cnt + 6'd1;
                    if (cnt == 6'd31) state <= DONE;   // 完成第 32 步
                end
                DONE: state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end

    assign busy = (state == CALC);
    assign done = (state == DONE);

    wire [31:0] q_abs = Q;
    wire [31:0] r_abs = R[31:0];
    assign quotient  = zero ? 32'hFFFFFFFF : (q_neg ? (~q_abs + 32'd1) : q_abs);
    assign remainder = zero ? dividend_r   : (r_neg ? (~r_abs + 32'd1) : r_abs);
endmodule
