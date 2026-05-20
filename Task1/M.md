# RV32M 乘法指令扩展

本文档介绍了在多周期流水线 CPU 中实现 RISC-V RV32M 扩展中的 `mul`, `mulh`, `mulhu` 乘法指令的原理与过程。

## 1. 外置模块作用解释

在 `src/CPU/` 目录下新增了以下四个文件，其功能分别如下：

1. **`CSA.v` (Carry-Save Adder)**
   实现了保留进位加法器。它接收三个多比特输入并并行输出不进位的“和 (Sum)”与左移一位的“进位 (Carry)”。此加法器无需等待进位传递信号（无 Ripple Carry），大幅度减少了多个数相加时的关键路径延迟，是构建华莱士树 (Wallace Tree) 的基础组件。

2. **`Mul.v` (Array / Wallace Multiplier)**
   实现了一个 32x32 位的组合逻辑乘法器。通过与门矩阵生成 32 个部分积，并使用 `CSA` 逐步将其压缩为两个操作数，最后通过一个标准加法器求和。

3. **`Mul_wallace.v`**
   结合了大步长基-4 布斯编码 (Radix-4 Booth Encoding) 和华莱士树的 32x32 位乘法器。通过 Booth 编码将部分积的数量从 32 个折半减小到了 16 个，再通过华莱士树进行连加压缩。

4. **`Mul_33.v`**
   实现了 **33x33 位的 Booth-Wallace 乘法器**。在处理 32 位有符号和无符号乘法时，我们可以将无符号数零扩展至 33 位，有符号数符号扩展至 33 位。该模块能够兼顾处理 `mul` / `mulh` (有符号乘法) 和 `mulhu` (无符号乘法)。

---

## 2. 加入流水线的原理与设计

为了支持 RV32M 乘法指令集（要求乘法至多在 5 个周期内完成且禁用 `*`），我们选择**将 `Mul_33.v` 实例化在流水线的 EX 阶段**。该模块是组合逻辑乘法器，只要时钟频率合理，单周期内即可输出结果，完全符合要求的“5 个周期内给出正确结果”。

对于这三条指令，`opcode` 均为 `0110011`，`funct7` 均为 `0000001`。
区别在于 `funct3`：
- `mul`：`funct3 = 000`，取结果低 32 位（无论操作数视为有符号还是无符号，低32位结果相同）。
- `mulh`：`funct3 = 001`，有符号乘法，取结果高 32 位。
- `mulhu`：`funct3 = 011`，无符号乘法，取结果高 32 位。

### 数据扩展方式
- 当 `funct3 == 011` (`mulhu`) 时，源操作数无符号，进行高位**零扩展** (即最高位补 `1'b0`)。
- 当 `funct3 == 001` (`mulh`) 或 `000` (`mul`) 时，对源操作数进行**符号扩展** (直接把符号位 `alu_src[31]` 拼接至第 32 位)。

---

## 3. 核心集成代码 (`CPU.v` 修改)

在 `src/CPU/CPU.v` 的 Execute 阶段 (EX) 中，添加标志位提取、操作数扩展、乘法器实例化并接入 `alu_res`：

```verilog
// ... 现有的其他运算 ...
wire [31:0] xor_res = alu_src1 ^ alu_src2;
wire [31:0] or_res  = alu_src1 | alu_src2;
wire [31:0] and_res = alu_src1 & alu_src2;

// 1. 判断当前是否为 RV32M 的乘法指令
wire ID_EX_is_mul = (ID_EX_inst[6:0] == 7'b0110011) && (ID_EX_funct7 == 7'b0000001);

// 2. 根据 funct3 对操作数进行 33 位的扩展处理
// funct3 == 3'b011 为 mulhu, 进行 0 扩展
// funct3 == 3'b000/001 为 mul/mulh, 进行符号扩展
wire [32:0] mul_src1 = (ID_EX_funct3 == 3'b011) ? {1'b0, alu_src1} : {alu_src1[31], alu_src1};
wire [32:0] mul_src2 = (ID_EX_funct3 == 3'b011) ? {1'b0, alu_src2} : {alu_src2[31], alu_src2};

// 3. 例化 33x33 乘法器
wire [65:0] mul_res_66;
Mul_33 u_mul(
    .a(mul_src1),
    .b(mul_src2),
    .res(mul_res_66)
);

// 4. 根据指令要求截取对于位数结果
// mul: 截取小端 [31:0]
// mulh/mulhu: 截取高位端 [63:32] (注意输入扩展到了 33 位所以实际总长为 66，高 32 位是 63:32)
wire [31:0] final_mul_res = (ID_EX_funct3 == 3'b000) ? mul_res_66[31:0] : mul_res_66[63:32];

// 5. 整合进 alu_res (修改了原有的 alu_res 逻辑)
wire [31:0] alu_res = (ID_EX_is_mul) ? final_mul_res :
                      (ID_EX_is_lui) ? alu_src2 :
                      (ID_EX_is_jal | ID_EX_is_jalr) ? (ID_EX_pc + 4) :
                      (ID_EX_is_add_forced) ? add_res :
                      // ...后接其它基础指令逻辑
```

这样扩展后，乘法器将与其他 ALU 指令平行计算，由 `ID_EX_is_mul` 控制将最终的乘法结果引入流水线的数据通路。由于 `Mul_33` 是彻底展开的组合逻辑电路，在一个时钟周期内运算就能完成，完全满足“至多 5 个周期给出正确结果”的任务要求，并且利用了 Wallace 树与 CSA 提升了性能。