# 缓存(Cache)接入流水线 CPU 的详细设计与修复过程

将 Cache 接入五级流水线 CPU，并不仅仅是替换掉原来的单周期数据存储器（Data Memory），更关键的是要处理由于缓存未命中（Cache Miss）带来的多周期延迟。这要求流水线的冒险控制单元（Hazard Unit）和 Difftest 仿真测试接口都要进行系统性的重构，以适应动态不确定的流水线时序。

以下是整个 Cache 接入以及后续 Bug 修复过程的详细整理。

---

## 1. 整体架构与握手信号切入

在五级流水线的 **MEM（访存）段**，原本直接与 Data Memory 交互的接口现在被替换为了 Cache 模块。Cache 与 CPU 的核心交互不再是单个周期的即时返回，而是通过一个**握手阻塞信号**来进行通信。

我们定义了以下关键信号：

-`mem_is_load` / `mem_is_store`: 标识当前处于 MEM 段的指令是否为访存指令。

-`cache_miss`: 由 Cache 模块输出，当遇到缓存未命中（或正在从主存回填线）时拉高。

-`mem_stall`: CPU 内部的综合停顿信号，`mem_stall = (mem_is_load || mem_is_store) && cache_miss;`。

当 `mem_stall` 拉高时，意味着整个流水线必须在这一个周期内“冻结”，等待数据就绪。

---

## 2. 冒险控制单元 (Hazard Unit) 的解耦重构 (核心难点)

在没有引入 Cache 时，最大的流水线停顿来源是 **Load-Use 数据冒险**。原本的 `HazardUnit` 往往将所有的停顿杂糅在一起处理，这在 Cache 接入后直接造成了**严重的丢指令 Bug**。

### 问题根源：

旧设计中，当发生冒险时，系统产生了全局的 `stall`，并且所有段的寄存器更新使能信号（`xxx_write`）都绑定到了 `~stall`：

```verilog

assign stall        = load_use_hazard || mem_stall;

assign IF_ID_write  = ~stall;

assign ID_EX_write  = ~stall;

assign EX_MEM_write = ~stall; // 致命错误：这导致下游段也被冻结！

```

当只发生 `load_use_hazard` 时，正常逻辑只应该停断前面的 PC 和 IF_ID，让流水线后半段继续流动把前面的指令排空。但如果 `EX_MEM_write` 被冻结，而同时触发了气泡插入（`flush_ID_EX=1`），被卡在 `ID_EX` 阶段的正确指令会直接被冲刷掉，导致指令凭空消失。

### 修复方案：区分“局部阻塞”与“全局冻结”

我将 `HazardUnit.v` 进行了修正：只有由于 Cache 没命中造成的 `mem_stall` 才允许全局冻结整个流水线中后段。Load-Use 导致的 `stall` 仅控制 IF 和 ID 段。

**关键代码 (`HazardUnit.v`)：**

```verilog

    // 综合流水线停顿信号：包含数据冒险与Cache延迟

    assign stall        = load_use_hazard || mem_stall;

  

    // 前端（IF/ID）由于任何原因的 stall 均需停顿

    assign PC_write     = ~stall;

    assign IF_ID_write  = ~stall;

  

    // 后端（EX/MEM/WB）只有在 Cache miss 时才允许停顿

    assign ID_EX_write  = ~mem_stall;

    assign EX_MEM_write = ~mem_stall;

    assign MEM_WB_write = ~mem_stall;

  

    // 控制冒险清空 IF/ID

    assign flush_IF_ID = control_hazard;

  

    // Load-Use阻塞导致气泡，或控制冒险需要冲洗。

    // 注意：如果是由于 mem_stall 导致的冻结，不能产生 flush，否则会误删正在等待内存的数据！

    assign flush_ID_EX = (load_use_hazard && !mem_stall) || control_hazard;

```

---

## 3. Difftest 验证框架的同步修复：防止指令重复提交

引入了 Cache Miss 和 `mem_stall` 以后，流水线的最后一级（`MEM_WB`）可能会在一块等待数个时钟周期。

### 问题根源：

Difftest 框架是通过 `commit` 信号来向 C++ 验证层汇报当前有一条新指令执行完毕的：

```verilog

assign commit = valid && global_en && MEM_WB_valid;

```

由于 `mem_stall` 时整个流水线的状态都在保持 (`MEM_WB_valid` 持续为高)，仿真框架在 Cache 阻塞的每一个周期都会以为同一条指令结束了，从而拉取结果去跟参考器比对，导致寄存器比对错误报错 (`reg_we`, `reg_wd` 多次生效等异常)。

### 修复方案：增加写使能判断

`commit` 操作必须要与流水排空的动作保持同步。如果我们在这一周期只是保持流水寄存器不变（即 `MEM_WB_write == 0`），则不仅不应推进状态机，也不应当发提交信号。

**关键代码 (`CPU.v`)：**

```verilog

/* 

 * 修正 commit 提交信号：

 * 将 MEM_WB_write 纳入与运算。

 * 即使发生了 MEM_WB_valid，如果在 Cache Miss 陷入 mem_stall 冻结期间，

 * MEM_WB_write=0，则屏蔽 commit 的触发，避免在阻塞时向 Difftest 发射伪同步。

 */

assign commit = valid && global_en && MEM_WB_valid && MEM_WB_write;

```

---

## 4. 内存操作状态向提交段 (WB) 的严格透传

最后一个隐蔽的 Bug 源于 DiffTest 对内存写入信号的校对（`dmem_we`、`wa`、`wd`）。

### 问题根源：

在旧的无 Cache CPU 中，由于没有指令驻留乱序的问题，仿真测试的存储器写验证口经常是偷懒直接接在大约 `EX_MEM` 级发出的：

```verilog

// 旧时代的写法

assign commit_dmem_we = EX_MEM_dmem_we && commit; 

```

当系统由于 Cache 引起停顿时，处于 `WB` 段真实正在触发 `commit` 的指令，和处在 `EX_MEM` 段刚刚执行完计算的**下一条指令**之间存在时序错位。Difftest 如果在检查 `commit` 时读取了 `EX/MEM` 段的信号，就把不属于本条指令的内存动作送去了验证，从而得到 `Expected: false, Got: true` 的报错。

### 修复方案：在 WB 阶段增加寄存器做信息对齐

内存操作特征应该像 `reg_we` 或 `pc` 那样，变成寄存器信息流，跟随该指令一并流转到 `MEM_WB` 验证口。

**关键代码 (`CPU.v` 段间寄存器修改)：**

```verilog

// 1. 在 MEM/WB 流水级增加了 Difftest 用到的专用寄存器

reg        MEM_WB_dmem_we;

reg [31:0] MEM_WB_dmem_wa;

reg [31:0] MEM_WB_dmem_wd;


always @(posedge clk) begin

    // ...

    } else if (global_en && valid && MEM_WB_write) begin

        // 2. 将来自 EX/MEM 访存周期的实际信号拍入 WB 段

        MEM_WB_dmem_we       <= EX_MEM_dmem_we;

        MEM_WB_dmem_wa       <= EX_MEM_alu_out;

        MEM_WB_dmem_wd       <= EX_MEM_reg_wd;

    // ...

    end

end


// 3. 将 Difftest Commit 接口绑定给被严格流水化保护的 WB 段实体

assign commit_dmem_we = MEM_WB_dmem_we && commit;

assign commit_dmem_wa = MEM_WB_dmem_wa;

assign commit_dmem_wd = MEM_WB_dmem_wd;

```

---

## 总结

Cache 接入导致的错误往往是由 **时序的突然改变** 牵一发而动全身造成的。原本在 1CPI 下被掩盖的逻辑漏洞，全部变成了显式的重灾区。从上述三个主要改动（`HazardUnit 解耦控制`、`Commit 的周期限定`、`验证信息的深层流水线化透传`），我们清除了仿真错位，实现了流水线 CPU 在可变延迟 Cache 中的完美衔接与满分测试验证。
