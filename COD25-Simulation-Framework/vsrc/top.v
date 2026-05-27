`timescale 1ns / 1ps
`include "configs.vh"

module
    Top (
        // basic ports
        input                   [ 0 : 0]                    clk,
        input                   [ 0 : 0]                    rst,

        // ports for simulation and difftest
        output                  [ 0 : 0]                    commit,
        output                  [ 0 : 0]                    commit_halt,

        // for difftest
        output                  [31 : 0]                    commit_pc,
        output                  [31 : 0]                    commit_instr,

        // compare commit
        output                  [ 0 : 0]                    commit_reg_we,
        output                  [ 4 : 0]                    commit_reg_wa,
        output                  [31 : 0]                    commit_reg_wd,
        output                  [ 0 : 0]                    commit_dmem_we,
        output                  [`DATA_MEM_DEPTH - 1 : 0]   commit_dmem_wa,
        output                  [31 : 0]                    commit_dmem_wd,

        // compare full status
        input                   [ 4 : 0]                    debug_reg_ra,
        output                  [31 : 0]                    debug_reg_rd,
        input                   [`DATA_MEM_DEPTH - 1 : 0]   debug_dmem_ra,
        output                  [31 : 0]                    debug_dmem_rd
    );

    wire [31 : 0] pc;
    wire [31 : 0] instr;

    // CPU <-> Cache signals
    wire [31 : 0] dmem_addr;
    wire [31 : 0] dmem_rdata;
    wire [31 : 0] dmem_wdata;
    wire [ 3 : 0] dmem_wmask;
    wire [ 0 : 0] dmem_we;
    wire [ 0 : 0] dmem_re;
    wire [ 0 : 0] cache_miss;

    // Cache <-> MemAdapter signals
    wire [ 0 : 0] cache_mem_r;
    wire [ 0 : 0] cache_mem_w;
    wire [31 : 0] cache_mem_addr;
    wire [127: 0] cache_mem_w_data;
    wire [127: 0] cache_mem_r_data;
    wire [ 0 : 0] cache_mem_ready;

    // MemAdapter <-> DataMem signals
    wire [31 : 0] adapt_phy_addr;
    wire [31 : 0] adapt_phy_wdata;
    wire [31 : 0] adapt_phy_rdata;
    wire [ 0 : 0] adapt_phy_we;

    wire [31 : 0] imem_paddr;
    wire [31 : 0] adapt_paddr;
    wire [31 : 0] commit_dmem_wa_raw;
    wire [31 : 0] commit_dmem_pwa;

    assign imem_paddr   = pc - `INSTR_MEM_START;
    assign adapt_paddr  = adapt_phy_addr - `DATA_MEM_START;
    assign commit_dmem_pwa = commit_dmem_wa_raw - `DATA_MEM_START;
    assign commit_dmem_wa  = commit_dmem_pwa[`DATA_MEM_DEPTH + 1 : 2];

    CPU cpu(
        .clk                    (clk),
        .rst                    (rst),
        .global_en              (1'B1),

        .imem_raddr             (pc),
        .imem_rdata             (instr),

        .dmem_addr              (dmem_addr),
        .dmem_rdata             (dmem_rdata),
        .dmem_wdata             (dmem_wdata),
        .dmem_wmask             (dmem_wmask),
        .dmem_we                (dmem_we),
        .dmem_re                (dmem_re),

        .cache_miss             (cache_miss),

        .commit                 (commit),
        .commit_pc              (commit_pc),
        .commit_instr           (commit_instr),
        .commit_halt            (commit_halt),
        .commit_reg_we          (commit_reg_we),
        .commit_reg_wa          (commit_reg_wa),
        .commit_reg_wd          (commit_reg_wd),
        .commit_dmem_we         (commit_dmem_we),
        .commit_dmem_wa         (commit_dmem_wa_raw),
        .commit_dmem_wd         (commit_dmem_wd),

        .debug_reg_ra           (debug_reg_ra),
        .debug_reg_rd           (debug_reg_rd)
    );

    InstrMem instr_mem(
        .a                      (imem_paddr[`INSTR_MEM_DEPTH + 1 : 2]),
        .spo                    (instr)
    );

    // Data cache: write-back write-allocate 2-way set-associative
    cache #(
        .INDEX_WIDTH            (3),
        .LINE_OFFSET_WIDTH      (2),
        .SPACE_OFFSET           (2),
        .WAY_NUM                (2)
    ) u_cache (
        .clk                    (clk),
        .rstn                   (~rst),

        .addr                   (dmem_addr),
        .r_req                  (dmem_re),
        .w_req                  (dmem_we),
        .w_data                 (dmem_wdata),
        .w_mask                 (dmem_wmask),
        .r_data                 (dmem_rdata),
        .miss                   (cache_miss),

        .mem_r                  (cache_mem_r),
        .mem_w                  (cache_mem_w),
        .mem_addr               (cache_mem_addr),
        .mem_w_data             (cache_mem_w_data),
        .mem_r_data             (cache_mem_r_data),
        .mem_ready              (cache_mem_ready)
    );

    // MemAdapter: bridges 128-bit cache line interface to 32-bit DataMem
    MemAdapter u_mem_adapter(
        .clk                    (clk),
        .rst                    (rst),

        .mem_r                  (cache_mem_r),
        .mem_w                  (cache_mem_w),
        .mem_addr               (cache_mem_addr),
        .mem_w_data             (cache_mem_w_data),
        .mem_r_data             (cache_mem_r_data),
        .mem_ready              (cache_mem_ready),

        .phy_mem_addr           (adapt_phy_addr),
        .phy_mem_wdata          (adapt_phy_wdata),
        .phy_mem_rdata          (adapt_phy_rdata),
        .phy_mem_we             (adapt_phy_we)
    );

    DataMem data_mem(
        .a                      (adapt_paddr[`DATA_MEM_DEPTH + 1 : 2]),
        .d                      (adapt_phy_wdata),
        .clk                    (clk),
        .we                     (adapt_phy_we),
        .spo                    (adapt_phy_rdata),
        .debug_a                (debug_dmem_ra),
        .debug_spo              (debug_dmem_rd)
    );

endmodule
