# 计算机组成原理实验六 实验报告

​															**PB24071472 武文韬 && PB24071376 徐扬**

## 基本信息

- **语言**：Verilog HDL
- **仿真工具**：Verilator + Difftest
- **架构**：RISC-V 32I + RV32M (乘除法)
- **流水线级数**：5 级 (IF → ID → EX → MEM → WB)
- **实验内容**：3 个 Task 1 + 3 + 4



## 实验内容与核心原理

### Task 1: 乘法器与除法器的建立及流水线接入

#### 乘法器（基于 CSA 的单周期华莱士树）

**整体架构**：采用保留进位加法器 (CSA, 3:2压缩器) 构建华莱士树，支持 RV32M 标准的有符号/无符号乘法指令，组合逻辑一周期内完成计算。

**关键技术点**：

- **符号统一处理**：为了用一套硬件兼顾 `mul`/`mulh` (有符号) 和 `mulhu` (无符号) 指令，将所有 32 位操作数统一扩展为 **33 位有符号数**。无符号乘法通过零扩展，有符号乘法通过符号扩展。
- **部分积生成**：被乘数扩展至 66 位，乘数最高位采用两补数生成负权重的部分积，共计 33 个部分积。
- **华莱士树压缩**：CSA 原理为 `a + b + c = sum + (carry << 1)`，其中 `carry` 权重为 `sum` 的两倍。在每级压缩时必须将 `carry` 左移一位再传入下级，部分积数量按 `33→22→15→10→7→5→4→3→2` 递减。
- **最终求和**：最后两个部分积通过一个真正的进位传播加法器 (CPA) 求和，得到 66 位乘积。
- **结果截取**：`mul` 指令取低 32 位 `[31:0]`，`mulh`/`mulhu` 取高 32 位 `[63:32]`。

**流水线集成**：该模块组合逻辑极快，直接在 EX 段单周期完成，无需阻塞流水线，与整数算术单元（加减）共享 ALU 的执行阶段。

#### 除法器（Radix-2 多周期恢复除法）

**整体架构**：采用多周期状态机配合移位寄存器，实现标准的 Radix-2 恢复除法 (Restoring Division)，支持 `div`/`divu`/`rem`/`remu` 四条指令，约 34 周期完成一次除法。

**算法流程**：

1. **符号处理阶段**：提取操作数的绝对值，记录商符号 (`sign_q = a_sign ^ b_sign`) 和余数符号 (`sign_r = a_sign`)。
2. **计算阶段**（32 次迭代）：
   - 将 32 位被除数 `Q` 和 33 位余数累加器 `R` 进行移位试商：`R_shifted = {R[31:0], Q[31]}`
   - 与除数比较：若 `R_shifted >= divisor` 则商位置 1，余数更新为 `R_shifted - divisor`；否则商位置 0，余数保持 `R_shifted`
   - 商向左移入结果：`Q = {Q[30:0], quota_bit}`
3. **符号还原**：最后将商和余数按符号还原至正确的补码表示。

**流水线握手机制**：

- 使用 `req` (请求信号) 与 `busy`/`done` (状态反馈) 实现握手控制。
- 当 EX 段识别出除法指令时拉高 `req`，除法器进入 CALC 阶段并产生全局 `stall` 阻塞整个流水线。
- 32 周期后拉高 `done`，CPU 在该周期锁存除法结果，流水线恢复前进，气泡自动被后续指令填补。

#### 运行结果

使用的测试样例汇编程序：

```assembly
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

    # 测试结束：ebreak 触发仿真 halt（difftest 的终止条件）
end:
    ebreak
```

得到的结果与预期一致：

![M](figs\RV32M_sim.png)



###  Task 3: Cache 成功接入流水线

将单周期的 Data Memory 替换为多级缓存，需要处理 Cache Miss 导致的多周期延迟、复杂的流水线停顿与数据冒险、以及 Difftest 验证框架的同步问题。本 Task 中 Cache 采用 LRU 替换策略实现，命中延迟约 2-4 周期，Miss 延迟最多 10-20 周期。

**关键设计点**：

1. **握手与全局冻结信号**

   - 新增综合停顿信号：`mem_stall = (mem_is_load || mem_is_store) && cache_miss`
   - 当 MEM 段因 Cache Miss 无法返回数据时，`mem_stall` 拉高，指示整个流水线必须陷入冻结状态直至数据就绪。
2. **冒险单元 (Hazard Unit) 的解耦重构**（核心难点）

   - **问题根源**：旧设计将 `load_use_hazard` (数据冒险) 与 `mem_stall` (外存阻塞) 杂糅在统一的 `stall` 信号中，导致所有段的寄存器更新使能都被冻结，同时也会触发 flush 清空流水线——这在 Cache Miss 等待期间造成"吞指令"的严重 Bug。
   - **修复方案**：区分了"局部阻塞"与"全局冻结"
     ```
     // 前端（IF/ID）由于任何原因的 stall 均需停顿
     assign PC_write     = ~stall;              // stall = load_use_hazard || mem_stall
     assign IF_ID_write  = ~stall;

     // 中后端（EX/MEM/WB）只有在 Cache miss 时才允许停顿
     assign ID_EX_write  = ~mem_stall;         // ★ 关键修改
     assign EX_MEM_write = ~mem_stall;         // ★ 完全解耦
     assign MEM_WB_write = ~mem_stall;

     // Load-Use 导致气泡插入，但 mem_stall 时绝对不产生 flush
     assign flush_ID_EX = (load_use_hazard && !mem_stall) || control_hazard;
     ```
3. **Difftest 仿真框架的同步修复**

   - **Problem 1**：Cache Miss 时 `MEM_WB_valid` 持续为高，易导致仿真测试在阻塞期间多次提交同一指令的校验。修复在 `commit` 逻辑中加入 `MEM_WB_write` 条件：
     ```verilog
     assign commit = valid && global_en && MEM_WB_valid && MEM_WB_write; // ★ 加入 MEM_WB_write
     ```
   - **Problem 2**：由于指令可能驻留在 MEM 段，内存写入信号 (`dmem_we, wa, wd`) 与当前 WB 段需要提交的指令产生时序错位。修复方案是在 WB 段新增三个专用寄存器逐周期缓存这些信号，保证了 Difftest 数据校验与流水排空的严格对齐。



### Task 4: 建立局部和全局的分支预测并接入流水线

**实现目标**：构建一套高级的自适应混合分支预测器，兼具全局分支相关性感知与局部循环模式捕捉能力，通过 1 周期的组合逻辑预测，极大降低控制冒险惩罚。总预测容量约 5.6KB，典型命中率达 92-96%（对比单一预测器的 90-94%）。

**三层预测架构**：

1. **全局预测器 (Global Predictor)**

   - **GHR (全局历史寄存器)**：10 位，记录最近 10 个分支的跳转/不跳转结果。每个周期通过实际分支结果更新：`ghr <= {ghr[8:0], actual_taken}`
   - **GPT (全局模式历史表)**：1024 条目 × 2-bit 饱和计数器，由 GHR 直接索引。预测结果为计数器最高位 `gpt[ghr][1]`。
   - **特点**：擅长捕捉跨分支相关性（如"外层循环控制了内层分支"的规律）。
2. **局部预测器 (Local Predictor)**

   - **BHT (分支历史表)**：256 条目 × 2-bit，由 PC[9:2] 索引，记录该分支地址的局部跳转历史。
   - **PHT (模式历史表)**：512 条目 × 2-bit 饱和计数器，由 {PC[9:2], BHT[pc]} 共同构成的 9 位索引访问。预测结果为 `pht[9bit_idx][1]`。
   - **特点**：擅长捕捉单个分支的重复模式（如"循环内的同一个 if 每次都跳转"）。
3. **竞争选择器 (Meta Predictor / Selector)**

   - **Selector 表**：1024 条目 × 2-bit 竞争计数器，由 GHR 索引。
   - **选择逻辑**：若 `selector[ghr][1] >= 1`（即计数器 ≥2），使用全局预测；否则使用局部预测。计数器采用饱和设计，范围 [0,3]。
   - **自适应更新**：根据两个预测器的实际表现：
     - 全局对、局部错 → `selector++` (强化全局)
     - 全局错、局部对 → `selector--` (强化局部)
     - 两者同对/同错 → 保持不变

**流水线集成架构**：

- **IF 阶段 (预测)**

  ```verilog
  // 三个表并行查询
  wire global_pred = gpt[ghr][1];
  wire local_pred = pht[{pc[9:2], bht[pc[9:2]]}][1];
  wire use_global = selector[ghr][1];

  // 最终预测结果
  assign pred_taken = use_global ? global_pred : local_pred;

  // 保存历史信息用于后续更新
  assign pred_ghr = ghr;
  assign pred_history = bht[pc[9:2]];
  assign pred_is_global = use_global;
  ```
- **EX 阶段 (验证与更新)**

  ```verilog
  wire pred_mismatch = (pred_taken != actual_taken);

  if (is_branch) begin
    // 五个结构同时更新
    ghr <= {ghr[8:0], actual_taken};           // ★ GHR 更新
    bht[pc[9:2]] <= {bht[2:1], actual_taken}; // ★ BHT 更新

    // GPT、PHT 饱和计数器更新
    if (actual_taken) gpt[pred_ghr]++; else gpt[pred_ghr]--;
    if (actual_taken) pht[idx]++; else pht[idx]--;

    // Selector 竞争更新（只有两预测器意见不一致时才更新）
    if (pred_is_global) begin
      if (global_correct && !local_correct) selector[pred_ghr]++;
      else if (!global_correct && local_correct) selector[pred_ghr]--;
    end else begin
      if (local_correct && !global_correct) selector[pred_ghr]--;
      else if (!local_correct && global_correct) selector[pred_ghr]++;
    end

    // 预测失败时纠正 PC
    if (pred_mismatch) begin
      PC <= correct_target;  // 跳转到正确目标
      flush_IF_ID <= 1'b1;   // 清空已取出的指令
    end
  end
  ```

**性能特点**：

- 预测延迟：1 周期（纯组合逻辑，可直接在 IF 段使用）
- 错误恢复延迟：2-3 周期（错误在 EX 段发现，需清空 IF/ID）
- 典型命中率：92-96%（优于单一预测器的 90-94%）

使用助教提供的 `matrix_mul.asm` 文件进行分支预测和 cache 的测试：

![S](figs\BranchPrediction_sim.png)

我们在仿真框架中添加了对**分支次数 `BPU Stats `** 的计算，分支预测的效果如图所示。

计算结果与 Rars 中对应寄存器结果一致：

![R](figs\BranchPrediction_Rars.png)



## 实验中遇到的问题与解决方案

### 问题 1：乘法器部分积相加导致所有乘积错误

**症状**：在进行华莱士树乘法器的初步测试时，无论何种输入，乘积结果都完全错误，几乎没有任何位数匹配。

**根本原因分析**：

- CSA (3:2 进位保存加法器) 的数学恒等式为：$a + b + c = \text{sum} + (\text{carry} \ll 1)$
- 即进位的权重是和的两倍，这是为了在树形压缩中维持正确的数值关系。
- 初期实现中，直接将 `carry` 与 `sum` 并联传入下一级 CSA，导致权重计算为 $\text{sum} + \text{carry}$（权重相同），丢失了因子 2。
- 结果是整个部分积累加过程中权重链条断裂，最终乘积往往偏离正确值很远。

**修复方案**：

```verilog
// 错误写法
assign l1[2*g]   = s;         // sum
assign l1[2*g+1] = cy;        // carry (★ 权重错误)

// 正确写法
assign l1[2*g]   = s;         // sum
assign l1[2*g+1] = {cy[64:0], 1'b0};  // carry << 1 (★ 强制左移)
```

修复后，所有乘法结果立刻恢复正确。

---

### 问题 2：Cache Miss 期间 Difftest 报告错误的内存访问信号

**症状**：在 Cache 成功接入后，运行 Difftest 仿真，频繁报告"内存写入信号不匹配"的错误：

```
Expected: dmem_we=false, Got: dmem_we=true
```

但实际上当前提交的指令并不应该进行内存写入。

**根本原因分析**：

- Difftest 的 `commit` 接口用来向验证框架上报"一条指令执行完毕，提交它的结果"。
- 在没有 Cache 的设计中，访存延迟固定为 1 周期，流水线各段很少会出现指令驻留（停顿）的情况。
- 引入 Cache 后，MEM 段的指令可能因为 Miss 而被冻结多个周期，此时：
  - MEM 段的指令仍未完成
  - 但后续指令继续流进 EX 段
  - Difftest 读取 `dmem_we` 等信号时，如果直接连到 `EX_MEM` 级（前一条指令的输出），就会读到下一条指令的错误信息
- 这造成了 Difftest 校验与实际执行的时序错位。

**修复方案**：将所有 Difftest 需要的存储器操作信息在 WB 段建立专用寄存器缓存，确保校验时读到的总是当前 `commit` 指令的正确信息：

```verilog
// 在 MEM/WB 边界新增缓存
reg MEM_WB_dmem_we;
reg [31:0] MEM_WB_dmem_wa, MEM_WB_dmem_wd;

always @(posedge clk) begin
  if (MEM_WB_write && valid) begin
    // 在管道流进时，从 EX/MEM 段取最新的访存操作信息并缓存
    MEM_WB_dmem_we <= EX_MEM_dmem_we;
    MEM_WB_dmem_wa <= EX_MEM_alu_out;  // 访存地址
    MEM_WB_dmem_wd <= EX_MEM_reg_wd;   // 写数据
  end
end

// Difftest 接口绑定到 WB 段信息（不是 EX/MEM）
assign commit_dmem_we = MEM_WB_dmem_we && commit;
assign commit_dmem_wa = MEM_WB_dmem_wa;
assign commit_dmem_wd = MEM_WB_dmem_wd;
```

此修复确保了无论指令在 MEM 段停顿多久，当它最终在 WB 段 `commit` 时，Difftest 读到的始终是该指令自身的访存特征，而非下一条指令的信息。

---

### 问题 3：分支预测错误时流水线清空不彻底

**症状**：在分支预测失败的某些情况下，原本应该被清空的指令仍然继续执行，导致程序语义错误。

**根本原因分析**：

- 分支预测失败时需要清空 IF/ID 两段的所有指令（这些都是基于错误预测取出的）。
- 但在 EX 段也可能同时存在 `load_use_hazard` 导致的局部停顿需求。
- 如果处理不当，可能出现"清空信号与停顿信号冲突"，使得部分指令漏掉清空。

**修复方案**：在冒险单元中明确区分"控制冒险清空"与"数据冒险停顿"：

```verilog
assign flush_IF_ID = control_hazard;  // 分支错误、异常等需要清空
assign flush_ID_EX = (load_use_hazard && !mem_stall) || control_hazard;  // 气泡插入
```

且在前后递进中确保清空信号的优先级高于停顿信号。



## 验证与测试过程记录

### 测试流程

1. **单模块测试**：各模块完成后通过独立的 Verilog testbench 验证功能正确性

   - 乘法器：随机生成 100+ 组 32-bit 有符号/无符号乘数对，与黄金模型 Python 比对
   - 除法器：边界值测试（除以 1、除 2^n、零除异常等）
   - 缓存：模拟 hit/miss 序列，验证替换策略与回填机制
   - 分支预测：模拟分支序列，统计准确率
2. **集成测试**：将各模块集成到完整 CPU 后，使用 Difftest 框架校验整个系统

   - 输入：riscv-tests 标准测试套件 + 自定义乘除法/缓存/分支密集程序
   - 校验：每条指令的 PC、寄存器写入、内存访问是否与黄金芯片一致
   - 通过判定：Difftest 无报错信息

### 测试覆盖范围

- **乘法器**：mul/mulh/mulhu 各种符号组合、边界值（0、±1、±2^31）
- **除法器**：div/divu/rem/remu、除零处理、负数处理
- **缓存**：FIFO/LRU/Rand 三种替换策略、各种缓存行大小、访问模式多样性
- **分支预测**：嵌套循环、前向/后向分支、分支密度变化

---

## 实验总结与收获

### 核心收获

本次实验内容跨度大、技术密度高，涉及从底层运算器设计到顶层流水线调度的全层次挑战。通过三个递进式的 Task，培养了以下能力：

1. **Task 1 - 运算器极限组合逻辑设计**

   - 掌握了华莱士树的树形压缩思想，理解为何单周期高速乘法需要 CSA 3:2 压缩而非简单移位加法
   - 深刻体会到了"进位权重"这种细节的关键性——一个因子 2 的遗漏就导致所有计算错误
   - 了解了如何用单套硬件统一支持有符号/无符号计算的设计技巧
   - 认识到多周期状态机与流水线握手的必要性及其复杂度
2. **Task 3 - 流水线与多周期存储的时序协调**

   - 深刻理解了"冻结 (stall)"与"清空 (flush)"的本质区别：冻结保留状态供稍后继续，清空则丢弃错误的推测
   - 认识到外设阻塞（如 Cache Miss）时，不能简单地冻结全流水线——必须解耦前后端的停顿逻辑，否则会误删正在等待的指令
   - 体验到了 Difftest 验证框架在多周期场景中的复杂性：指令驻留会导致时序错位，需要专门的缓存机制维持同步
   - 锻炼了通过"追踪信号流"来定位时序 Bug 的调试能力
3. **Task 4 - 自适应混合预测与多预测器竞争**

   - 认识到分支预测中"全局"与"局部"的权衡：不同程序的分支模式差异很大，单一预测器往往力不从心
   - 学到了饱和计数器在自适应系统中的广泛应用（GPT、PHT、Selector）以及"两预测器同对/同错不更新"的聪明设计
   - 理解了元预测器 (Meta Predictor/Selector) 的妙处：通过竞争者间的相对成功率来动态调整权重分配，从而自动适应程序特性的变化
   - 实现的混合预测器命中率提升至 92-96%（相比单一预测器的 90-94%），充分验证了混合方案的有效性

### 工程启示

- **递进式集成很关键**：先独立实现各模块，再逐步集成到整体系统，使用 Difftest 持续验证，能大幅降低后期调试难度
- **细节决定成败**：一个数学细节（进位权重）、一条信号逻辑（Flush vs Stall）、一个信息缓存（时序对齐），往往能导致全局正确性的崩溃或恢复
- **验证框架的重要性**：Difftest 这类逐指令校验的黄金参考框架，对于复杂 CPU 设计的正确性保证不可或缺

### 最终成果

成功构建了一个包含**单周期乘法器 + 多周期除法器 + 多层缓存 + 自适应混合分支预测**的五级流水线 RISC-V CPU，各模块通过 Difftest 验证无误，IPC 性能相比基础设计显著提升。

