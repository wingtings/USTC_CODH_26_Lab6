# RV32M 乘除法指令扩展

本文档介绍在五级流水线 CPU 中实现 RISC-V RV32M 扩展（`mul/mulh/mulhu` 与 `div/divu/rem/remu`）的原理、关键代码与流水线集成方式。

**约束**：乘法器至多 5 周期给出结果（即禁止"循环加法"），乘除法均不得使用 IP 核或 `*`、`/`、`%` 运算符。

## 1. 模块总览（`src/CPU/`）

| 文件 | 作用 |
| --- | --- |
| `CSA.v` | 保留进位加法器（3:2 压缩器），华莱士树的基础组件 |
| `Mul_wallace.v` | 33×33 有符号华莱士树乘法器，组合单周期，覆盖 mul/mulh/mulhu |
| `Div.v` | Radix-2 移位除法器，多周期、状态机控制，覆盖 div/divu/rem/remu |

---

## 2. 乘法器：CSA + 华莱士树

### 2.1 为什么用华莱士树

32 位移位乘法需要 32 周期、逐级串行相加；超前进位加法器虽不依赖前一位进位，但高位逻辑层数仍随位宽增长。**保留进位加法器（CSA）** 把"三个数求和"压成"两个数求和"且**不传播进位**，关键路径仅一级全加器。用 CSA 搭成树，每层把部分积数量按约 2/3 缩减，最终只剩两个数，再用一个真正的加法器（CPA）求和——延迟为 O(log n) 级，组合单周期即可完成，满足"≤5 周期且非循环加法"。

### 2.2 CSA（3:2 压缩器）

```verilog
// sum   = a^b^c          按位无进位和
// carry = ab|bc|ca       按位进位（权重为 2）
// 恒等式：a + b + c == sum + (carry << 1)
assign sum   = a ^ b ^ c;
assign carry = (a & b) | (b & c) | (c & a);
```

> **关键**：`carry` 权重是 2，送入下一级 CSA 之前必须**左移一位**。旧实现正是漏掉这一步，把 `a+b+c` 错算成 `sum+carry`，导致几乎所有乘积错误。

### 2.3 统一有符号化：33 位扩展

`mul/mulh` 是有符号乘法、`mulhu` 是无符号乘法。把 32 位操作数统一扩展为 **33 位有符号数**即可用一次乘法覆盖三者：

- `mulhu`（funct3=011）：高位补 0（零扩展，33 位仍为非负，等价无符号）。
- `mul/mulh`：符号扩展。

### 2.4 部分积与华莱士树

把被乘数 `a` 符号扩展到 66 位 `aext`，乘数 `b` 的最高位（第 32 位）取**负权重**（两补数）：

```
a*b = Σ_{i=0..31} b[i]·(aext<<i)  −  b[32]·(aext<<32)     // 共 33 个部分积
```

```verilog
wire [65:0] aext = {{33{a[32]}}, a};
generate for (i=0;i<32;i=i+1) begin
    assign pp[i] = b[i] ? (aext << i) : 66'd0;            // 低 32 位正权重
end endgenerate
assign pp[32] = b[32] ? (~(aext << 32) + 66'd1) : 66'd0;  // 符号位负权重(取两补数)
```

33 个部分积经华莱士树逐级压缩（每级 `carry<<1`），数量变化 **33→22→15→10→7→5→4→3→2**，最后用一个加法器求和：

```verilog
CSA #(66) u(.a(l0[3*g]), .b(l0[3*g+1]), .c(l0[3*g+2]), .sum(s), .carry(cy));
assign l1[2*g]   = s;
assign l1[2*g+1] = {cy[64:0], 1'b0};   // ★ carry 左移一位再进下一级
...
assign res = l8[0] + l8[1];            // 最后两数用真正的加法器(CPA)求和
```

结果截取：`mul` 取 `res[31:0]`，`mulh/mulhu` 取 `res[63:32]`。

---

## 3. 除法器：Radix-2 移位除法器（多周期 + 状态机）

除法无法廉价组合化（查表资源/延迟过大），因此用**多周期**实现，并由**状态机**与流水线 EX 段握手。

### 3.1 算法（恢复除法）

- **符号处理**：开始前记录商符号（被除数^除数）、余数符号（被除数），并把操作数转为绝对值；结束后按符号还原。
- **核心**：`|被除数|` 放入移位寄存器 `Q`，余数累加器 `R`（33 位，防左移溢出）。每步：

```verilog
wire [32:0] shifted_R = {R[31:0], Q[31]};            // 左移并移入被除数当前最高位
wire        ge        = (shifted_R >= {1'b0, ubr});  // 试商：够减则商位=1
wire [32:0] R_step    = ge ? (shifted_R - {1'b0, ubr}) : shifted_R;
wire [31:0] Q_step    = {Q[30:0], ge};               // 低位补入商位
```

32 步后 `Q = |商|`，`R[31:0] = |余数|`，再按符号还原。

### 3.2 状态机与握手

```
IDLE --req--> CALC --(32步, cnt=31)--> DONE --> IDLE
```

- `req`：EX 段存在除法指令（电平，整个停顿期间为高）。
- `busy/done`：`done` 在结果就绪时拉高一拍，CPU 在这一拍放行流水线并锁存结果。
- `en = global_en && valid`：流水线时钟使能，低时状态机暂停以与流水线保持同步。
- 操作数在 `IDLE→CALC` 时一次性锁存（绝对值、符号、除零标志），停顿期间不受前递变化影响。

### 3.3 RISC-V 特殊情形

```verilog
assign quotient  = zero ? 32'hFFFFFFFF : (q_neg ? (~q_abs + 1) : q_abs);  // 除零：商=-1
assign remainder = zero ? dividend_r   : (r_neg ? (~r_abs + 1) : r_abs);  // 除零：余数=被除数
```

> 有符号溢出 `0x80000000 / 0xFFFFFFFF` 由通用路径自然得到 商=`0x80000000`、余数=`0`，无需特判。

---

## 4. 流水线集成（`CPU.v` EX 段）

### 4.1 指令译码与操作数

RV32M 的 `opcode=0110011 & funct7=0000001`；`funct3[2]` 区分乘/除：

```verilog
wire ID_EX_is_m   = (ID_EX_inst[6:0]==7'b0110011) && (ID_EX_funct7==7'b0000001);
wire ID_EX_is_mul = ID_EX_is_m & ~ID_EX_funct3[2];   // 000/001/011 → mul/mulh/mulhu
wire ID_EX_is_div = ID_EX_is_m &  ID_EX_funct3[2];   // 100/101/110/111 → div/divu/rem/remu

// 乘法 33 位扩展 + 例化华莱士树
wire [32:0] mul_src1 = (ID_EX_funct3==3'b011) ? {1'b0,ex_fw_rv1} : {ex_fw_rv1[31],ex_fw_rv1};
wire [32:0] mul_src2 = (ID_EX_funct3==3'b011) ? {1'b0,ex_fw_rv2} : {ex_fw_rv2[31],ex_fw_rv2};
Mul_wallace u_mul(.a(mul_src1), .b(mul_src2), .res(mul_res_66));
wire [31:0] final_mul_res = (ID_EX_funct3==3'b000) ? mul_res_66[31:0] : mul_res_66[63:32];

// 除法例化（多周期握手）
wire div_in_ex = ID_EX_valid && ID_EX_is_div;
assign div_stall = div_in_ex && !div_done;            // 未完成则停顿
Div u_div(.clk(clk), .rst(rst), .en(global_en && valid), .req(div_in_ex),
          .a(ex_fw_rv1), .b(ex_fw_rv2), .is_signed(~ID_EX_funct3[0]),
          .busy(div_busy), .done(div_done), .quotient(div_q), .remainder(div_r));
wire [31:0] final_div_res = ID_EX_funct3[1] ? div_r : div_q;   // funct3[1]: 1=rem 0=div
```

### 4.2 乘法器为组合单周期，无需停顿

`Mul_wallace` 在一个周期内出结果，直接并入 `alu_res`：

```verilog
wire [31:0] alu_res = (ID_EX_is_div) ? final_div_res :
                      (ID_EX_is_mul) ? final_mul_res : /* 其余基础指令 ... */;
```

### 4.3 除法多周期停顿

除法在 EX 占用多周期，需冻结上游、向下游注入气泡：

- **冻结 PC / IF-ID / ID-EX**：`div_stall` 期间各级间寄存器写使能加 `&& !div_stall`，把除法指令"钉"在 EX。
- **EX/MEM 注入气泡**：停顿期间 EX/MEM 锁存 NOP（`valid/reg_we/dmem_we=0`），避免未就绪结果写回或访存。
- **`done` 放行**：除法完成那一拍 `div_stall=0`，EX/MEM 锁存真正的除法结果，流水线继续；下一条指令若依赖除法结果，由现有 EX 前递（从 EX/MEM）解决。

```verilog
// PC / IF-ID / ID-EX：写使能均追加 && !div_stall
else if (global_en && valid && PC_write && !div_stall) pc <= nextpc;
...
// EX/MEM：停顿期间注入气泡
if (div_stall) begin EX_MEM_valid<=0; EX_MEM_reg_we<=0; EX_MEM_dmem_we<=0; EX_MEM_inst<=32'h13; ... end
else            begin EX_MEM_alu_res<=alu_res; ... end
```

---

## 5. 验证

用 iverilog 仿真：

- **`Mul_wallace`**：≥12000 组随机 + 边界用例（`0x80000000²`、`0x80000000×-1`、全 1 等）对照参考值，mul/mulh/mulhu 全部 0 错。
- **`Div`**：≥4000 组随机 + 边界用例（负数、有符号溢出、除零、商 0）0 错。
- **CPU 整机**：汇编程序覆盖 mul/mulh/mulhu/div/divu/rem/remu、负数、除零、除法结果的前递（`x13=x4+1`）、背靠背除法，寄存器结果全部正确，停顿与放行时序正确。
