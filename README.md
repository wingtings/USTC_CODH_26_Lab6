# ODH LAB 6 report

**PB24071472 武文韬 && PB24071376 徐扬**

## Task 1 指令集扩展（M）

> 请查询相关资料，设计乘除法运算单元，在流水线处理器中支持下面的 RV32M 指令。
>
> * mul, mulh, mulhu
> * div, divu, rem, remu
>
> 要求：乘法器能在至多 5 个周期内给出正确结果（也就是 ban 了循环加法）；乘法器和除法器均**不允许**使用 IP 核或 `*`、`/`、`%` 运算符。
>
> 为了验证正确性，你需要为这些指令设计合适的测试汇编程序，最后上板运行比对结果。

## **Task 3**

> 请将 Lab5 设计的数据高速缓存接入流水线。注意：目前 PDU 内置的存储器是没有读写延迟的，为了与 Lab5 的 Cache 适配，你需要修改部分框架代码。
>
> 说明：
>
> 本项的难度较高。如果你不想使用 Lab5 的框架，我们也提供了往年的[框架](https://soc.ustc.edu.cn/CODH/2026/lab6/cache.zip)、[补充文件](https://soc.ustc.edu.cn/CODH/2026/lab6/MEM.v)以及[快速排序](https://soc.ustc.edu.cn/CODH/2026/lab6/qsort.txt)供大家参考。注意：本次实验只需要接入数据高速缓存。

### Task 4 分支预测

> Lab4 的流水线 CPU 在遇到需要跳转的分支指令时，需要冲刷 IF、ID 段的两条指令，对处理器的性能产生很大影响。分支预测技术是指处理器在 IF 阶段预测分支的跳转与否以及跳转目标地址，根据预测结果来实现不间断的指令流，从而让处理器的 CPI 接近理想情况中的 1。
>
> 请结合相关的资料，实现下面的内容：
>
> 1. 基于局部历史的分支预测
>    设计 BHT 与 PHT 的结构，并接入流水线 CPU。正确修改预测失败后流水线与分支预测器的相关内容。
> 2. 基于全局历史的分支预测以及竞争处理
>    设计全局预测器的结构，并设计算法处理全局预测与局部预测结果不一致时的竞争关系，以及对于全局预测器的实时修正。
>
> 你可以通过提供的[矩阵乘法程序](https://soc.ustc.edu.cn/CODH/2026/lab6/matrix_mul.asm)检验分支预测的效果。

---

# 实现说明（正确做法 / 关键代码 / 文件树）

## 文件树（核心）

```
src/
├── CPU/
│   ├── CPU.v             # 五级流水线顶层（EX 接入 mul/div，IF 接入分支预测）
│   ├── CSA.v             # ★ 保留进位加法器(3:2 压缩器)，华莱士树基础组件
│   ├── Mul_wallace.v     # ★ 33×33 有符号华莱士树乘法器：mul / mulh / mulhu
│   ├── Div.v             # ★ Radix-2 移位除法器(多周期+状态机)：div / divu / rem / remu
│   ├── BranchPredictor.v # ★ 竞争式分支预测：局部(BHT+PHT) + 全局(GHR+GPT) + 选择器
│   ├── regfile.v         # 寄存器堆（写优先转发）
│   ├── HazardUnit.v      # load-use 阻塞 + 控制冒险冲刷
│   └── ForwardingUnit.v  # EX 前递
├── MEM/ (MEM.v / MEM_BRIDGE.v / MMIO.v)   # 访存桥接与 MMIO
├── PDU/ ...                                # 下载/调试单元（UART）
└── TOP.v                                   # 顶层，例化 CPU/PDU/存储/MMIO
Task1/  Task3/(独立 Cache)  Task4/          # 各任务的独立代码与文档
```

> 验证：以上模块均用 iverilog 仿真通过。`Mul_wallace` 跑 ≥12000 组、`Div` 跑 ≥4000 组随机/边界用例 0 错；
> 在 CPU 整机 testbench 中跑 mul/mulh/mulhu/div/divu/rem/remu（含负数、除零、除法结果前递、背靠背除法）全部正确，多周期除法停顿与放行时序正确。

## Task 1 正确做法

### 1) 乘法器 `CSA.v` + `Mul_wallace.v`（无 IP、无 `*`、非循环加法）

PDF 明确禁止"循环加法"。故乘法器用**保留进位加法器(CSA)构成的华莱士树**实现：组合单周期，
关键路径为 O(log n) 级 CSA + 一个最终加法器，远优于 32 级串行加法。

**操作数扩展**：调用方在 EX 阶段把 32 位操作数扩展为 **33 位有符号数**——`mulhu` 高位补 0，
`mul/mulh` 符号扩展——于是一次有符号 33×33→66 位乘法即可统一覆盖三条指令。

**部分积**：把被乘数 `a` 符号扩展到 66 位 `aext`，乘数 `b` 的最高位取**负权重**：

```
a*b = Σ_{i=0..31} b[i]·(aext<<i)  −  b[32]·(aext<<32)   // 第 32 项取两补数，共 33 个部分积
```

**CSA(3:2 压缩器)**：`sum=a^b^c`，`carry=ab|bc|ca`，满足 `a+b+c == sum + (carry<<1)`。

```verilog
// 华莱士树逐级把部分积数量按 ~2/3 缩减：33→22→15→10→7→5→4→3→2
CSA #(66) u(.a(l0[3*g]), .b(l0[3*g+1]), .c(l0[3*g+2]), .sum(s), .carry(cy));
assign l1[2*g]   = s;
assign l1[2*g+1] = {cy[64:0], 1'b0};   // ★ 进位权重为 2，送下一级前必须左移一位
...
assign res = l8[0] + l8[1];            // 最后两数用真正的加法器(CPA)求和
```

> 关键正确性点（旧版正是栽在这两处）：① 每个 CSA 的进位 `carry` 必须 `<<1` 再送入下一级
> （否则把 `a+b+c` 错算成 `sum+carry`）；② 部分积要覆盖到第 32 位负权重项，不能漏。
> 本实现不用 Booth、直接铺 33 个部分积进华莱士树，逻辑更直观且经 ≥12000 组用例验证无误。

### 2) 除法器 `Div.v`（Radix-2 移位除法器，多周期 + 状态机，无 IP、无 `/`、`%`）

除法无法廉价组合化，故用**多周期**实现并由**状态机**与流水线握手：取绝对值 → 32 步移位**恢复除法** → 按符号还原。

```verilog
// 状态机：IDLE --req--> CALC --(32步)--> DONE --> IDLE
// 单步恢复除法：R(33位)防左移溢出，Q 存 |被除数| 并移入商位
wire [32:0] shifted_R = {R[31:0], Q[31]};            // 左移并移入被除数当前最高位
wire        ge        = (shifted_R >= {1'b0, ubr});  // 试商：够减则商位=1
wire [32:0] R_step    = ge ? (shifted_R - {1'b0, ubr}) : shifted_R;
wire [31:0] Q_step    = {Q[30:0], ge};
// 32 步后 Q=|商|、R[31:0]=|余数|，按符号还原；除零：商全 1、余数=被除数
assign quotient  = zero ? 32'hFFFFFFFF : (q_neg ? ~q_abs+1 : q_abs);
assign remainder = zero ? dividend_r   : (r_neg ? ~r_abs+1 : r_abs);
```

> 握手：`req` 在 EX 有除法指令时为高，`done` 就绪一拍放行流水线；操作数在 `IDLE→CALC` 一次性锁存。
> 有符号溢出 `0x80000000 / 0xFFFFFFFF` 由通用路径自然得到 商=`0x80000000`、余数=`0`，无需特判。

### 3) EX 阶段接入（`CPU.v`）

RV32M 的 `opcode=0110011 & funct7=0000001`；用 `funct3` 三位分别选择运算类别 / 商余数 / 符号：

```verilog
wire ID_EX_is_m   = (ID_EX_inst[6:0]==7'b0110011) && (ID_EX_funct7==7'b0000001);
wire ID_EX_is_mul = ID_EX_is_m & ~ID_EX_funct3[2];   // 000/001/011 → mul/mulh/mulhu
wire ID_EX_is_div = ID_EX_is_m &  ID_EX_funct3[2];   // 100/101/110/111 → div/divu/rem/remu
// 多周期除法：req 在 EX 有除法时拉高，done 就绪放行；未完成则 div_stall 停顿
wire div_in_ex = ID_EX_valid && ID_EX_is_div;
assign div_stall = div_in_ex && !div_done;
Div u_div(.clk(clk), .rst(rst), .en(global_en && valid), .req(div_in_ex),
          .a(ex_fw_rv1), .b(ex_fw_rv2), .is_signed(~ID_EX_funct3[0]),
          .busy(div_busy), .done(div_done), .quotient(div_q), .remainder(div_r));
wire [31:0] final_div_res = ID_EX_funct3[1] ? div_r : div_q;   // funct3[1]:1=rem 0=div
wire [31:0] alu_res = ID_EX_is_div ? final_div_res :
                      ID_EX_is_mul ? final_mul_res : /* 其余基础指令 ... */;
```

满足要求：无 IP 核、无 `*`/`/`/`%`，乘法为组合单周期（≤5 周期），除法为多周期 Radix-2（状态机握手）。
多周期除法停顿：`div_stall` 期间冻结 PC/IF-ID/ID-EX（写使能加 `&& !div_stall`）、向 EX/MEM 注入气泡，
`done` 那一拍放行并锁存结果；下一条依赖指令由现有 EX 前递解决。均复用现有前递操作数 `ex_fw_rv1/2`。

## Task 4 正确做法：竞争式（Tournament）分支预测

结构 = **局部预测**(BHT 256×2bit + PHT 512×2bit，索引 `{pc[9:2],局部历史}`) +
**全局预测**(GHR 10bit + GPT 1024×2bit，索引 GHR) + **竞争选择器**(sel 1024×2bit，由 GHR 索引)。
IF 阶段三路并行组合预测，选择器最高位决定采用全局还是局部；EX 阶段用流水线传下来的索引验证并更新。

```verilog
// IF：三路并行，选择器拍板
wire local_pred  = pht[{pc_if[9:2], bht[pc_if[9:2]]}][1];
wire global_pred = gpt[ghr][1];
wire use_global  = sel[ghr][1];
assign pred_taken     = use_global ? global_pred : local_pred;
assign pred_history   = bht[pc_if[9:2]];   // 随指令流水下传
assign pred_ghr       = ghr;               // 随指令流水下传
assign pred_is_global = use_global;        // 随指令流水下传

// EX：用保存的索引更新（饱和计数器 + GHR 移位 + 选择器“谁对偏向谁”）
if (is_branch_ex) begin
    pht[{pc_ex[9:2],pred_history_ex}] <= sat(±1);   // 局部
    bht[pc_ex[9:2]] <= {pred_history_ex[0], actual_taken};
    gpt[pred_ghr_ex] <= sat(±1);                    // 全局
    if ( global_correct & ~local_correct) sel[pred_ghr_ex] <= sat(+1); // 偏全局(高)
    if (~global_correct &  local_correct) sel[pred_ghr_ex] <= sat(-1); // 偏局部(低)
    ghr <= {ghr[8:0], actual_taken};
end
```

CPU 集成关键点：

- 在 `IF/ID`、`ID/EX` 级间寄存器中新增传递 4 个预测信息：`pred_taken / pred_history / pred_ghr / pred_is_global`，
  保证 EX 更新用的是**预测当时**的索引。
- 预测错误检测沿用：`pred_mismatch = ID_EX_is_branch && (ID_EX_pred_taken != branch_taken)`；
  错误时冲刷 IF/ID 并把 PC 纠正为分支真实方向（`HazardUnit.npc_sel_ex` 已含 `pred_mismatch`）。
- IF 阶段只有当取到的指令确实是分支(`opcode==1100011`)时才采用 `pred_taken` 重定向目标，避免误重定向。
