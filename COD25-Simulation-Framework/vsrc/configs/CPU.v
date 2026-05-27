`timescale 1ns / 1ps
module CPU(
    input  wire        clk,
    input  wire        rst,
    input  wire        global_en,
    
    // imem
    output wire [31:0] imem_raddr,
    input  wire [31:0] imem_rdata,
    
    // dmem
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [ 3:0] dmem_wmask,  // 新增：字节掩码
    input  wire [31:0] dmem_rdata,
    output wire        dmem_we,

    // cache interface
    input  wire        cache_miss,  // Cache 未命中信号（由外部 cache 驱动）
    output wire        dmem_re,     // data memory read enable (EX/MEM stage load)

    // trace debug
    output wire        commit,
    output wire [31:0] commit_pc,
    output wire [31:0] commit_instr,
    output wire        commit_halt,
    output wire        commit_reg_we,
    output wire [ 4:0] commit_reg_wa,
    output wire [31:0] commit_reg_wd,
    output wire        commit_dmem_we,
    output wire [31:0] commit_dmem_wa,
    output wire [31:0] commit_dmem_wd,

    input  wire [ 4:0] debug_reg_ra,
    output wire [31:0] debug_reg_rd
);


reg valid;
always @(posedge clk) begin
    if (rst) valid <= 1'b0;
    else if (global_en) valid <= 1'b1;
end

// ==========================================
// 级间寄存器声明 (Pipeline Registers)
// ==========================================
// IF/ID 段
reg        IF_ID_valid;
reg [31:0] IF_ID_pc;
reg [31:0] IF_ID_inst;
reg        IF_ID_pred_taken;
reg [ 1:0] IF_ID_pred_history;
reg [ 9:0] IF_ID_pred_ghr;
reg        IF_ID_pred_is_global;

// ID/EX 段
reg        ID_EX_valid;
reg [31:0] ID_EX_pc;
reg [31:0] ID_EX_inst;
reg        ID_EX_pred_taken;
reg [ 1:0] ID_EX_pred_history;
reg [ 9:0] ID_EX_pred_ghr;
reg        ID_EX_pred_is_global;
reg [31:0] ID_EX_rv1, ID_EX_rv2, ID_EX_imm;
reg [ 4:0] ID_EX_rs1, ID_EX_rs2, ID_EX_rd;
reg        ID_EX_is_load, ID_EX_is_store;
reg        ID_EX_reg_we, ID_EX_dmem_we;
reg [ 2:0] ID_EX_funct3;
reg        ID_EX_is_branch;

// EX/MEM 段
reg        EX_MEM_valid;
reg [31:0] EX_MEM_pc;
reg [31:0] EX_MEM_inst;
reg [31:0] EX_MEM_alu_res;
reg [31:0] EX_MEM_store_data;
reg [ 4:0] EX_MEM_rd;
reg        EX_MEM_reg_we, EX_MEM_dmem_we, EX_MEM_is_load;
reg [ 2:0] EX_MEM_funct3;

// MEM/WB 段
reg        MEM_WB_valid;
reg [31:0] MEM_WB_pc;
reg [31:0] MEM_WB_inst;
reg [31:0] MEM_WB_alu_res;
reg [31:0] MEM_WB_load_data; // 或dmem_rdata
reg [ 4:0] MEM_WB_rd;
reg        MEM_WB_reg_we, MEM_WB_is_load;
reg [ 2:0] MEM_WB_funct3;
reg        MEM_WB_dmem_we;
reg [31:0] MEM_WB_dmem_wa;
reg [31:0] MEM_WB_dmem_wd;

reg [31:0] pc;
wire       stall, PC_write, IF_ID_write, flush_IF_ID, flush_ID_EX;
// 多周期除法器停顿：除法在 EX 段计算期间冻结 PC/IF-ID/ID-EX，并向 EX/MEM 注入气泡
wire       div_stall, div_done, div_busy;

always @(posedge clk) begin
    if (rst) pc <= 32'h00400000;
    else if (global_en && valid && PC_write && !div_stall) pc <= nextpc;
end

always @(posedge clk) begin
    if (rst || flush_IF_ID) begin
        IF_ID_valid <= 1'b0;
        IF_ID_pc   <= 32'b0;
        IF_ID_inst <= 32'h00000013; // nop (addi x0, x0, 0)
        IF_ID_pred_taken <= 1'b0;
        IF_ID_pred_history <= 2'b0;
        IF_ID_pred_ghr <= 10'b0;
        IF_ID_pred_is_global <= 1'b0;
    end else if (global_en && valid && IF_ID_write && !div_stall) begin
        IF_ID_valid <= 1'b1;
        IF_ID_pc   <= pc;
        IF_ID_inst <= imem_rdata;
        IF_ID_pred_taken <= pred_taken;
        IF_ID_pred_history <= pred_history;
        IF_ID_pred_ghr <= pred_ghr;
        IF_ID_pred_is_global <= pred_is_global;
    end
end

assign imem_raddr = rst ? 32'h00400000 : pc;

// ==========================================
// Fetch Stage (IF)
// ==========================================
wire jump_taken;
wire branch_taken;
wire [31:0] jump_branch_target;

wire pred_mismatch = ID_EX_is_branch && (ID_EX_pred_taken != branch_taken);

wire pred_taken;
wire [1:0] pred_history;
wire [9:0] pred_ghr;
wire pred_is_global;

BranchPredictor u_bp(
    .clk(clk),
    .rst(rst),
    .pc_if(pc),
    .pred_taken(pred_taken),
    .pred_history(pred_history),
    .pred_ghr(pred_ghr),
    .pred_is_global(pred_is_global),
    .pc_ex(ID_EX_pc),
    .is_branch_ex(ID_EX_is_branch),
    .actual_taken(branch_taken),
    .pred_wrong(pred_mismatch),
    .pred_history_ex(ID_EX_pred_history),
    .pred_ghr_ex(ID_EX_pred_ghr),
    .pred_is_global_ex(ID_EX_pred_is_global)
);

// Target prediction
wire [31:0] if_inst = imem_rdata;
wire if_is_branch = (if_inst[6:0] == 7'b1100011);
wire [31:0] if_imm_B = {{20{if_inst[31]}}, if_inst[7], if_inst[30:25], if_inst[11:8], 1'b0};
wire if_pred_jump = if_is_branch && pred_taken;
wire [31:0] if_pred_target = pc + if_imm_B;

wire [31:0] nextpc = 
    pred_mismatch ? (branch_taken ? (ID_EX_pc + ID_EX_imm) : (ID_EX_pc + 4)) :
    jump_taken ? jump_branch_target : 
    if_pred_jump ? if_pred_target : 
    (pc + 4);

// ==========================================
// Decode Stage (ID)
// ==========================================
wire [31:0] id_inst = IF_ID_inst;
wire [6:0] id_opcode = id_inst[6:0];
wire [2:0] id_funct3 = id_inst[14:12];
wire [6:0] id_funct7 = id_inst[31:25];
wire [4:0] id_rs1 = id_inst[19:15];
wire [4:0] id_rs2 = id_inst[24:20];
wire [4:0] id_rd  = id_inst[11:7];

wire id_is_lui    = (id_opcode == 7'b0110111);
wire id_is_auipc  = (id_opcode == 7'b0010111);
wire id_is_jal    = (id_opcode == 7'b1101111);
wire id_is_jalr   = (id_opcode == 7'b1100111);
wire id_is_branch = (id_opcode == 7'b1100011);
wire id_is_load   = (id_opcode == 7'b0000011);
wire id_is_store  = (id_opcode == 7'b0100011);
wire id_is_imm    = (id_opcode == 7'b0010011);
wire id_is_reg    = (id_opcode == 7'b0110011);
wire id_is_system = (id_opcode == 7'b1110011);

wire [31:0] id_imm_I = {{20{id_inst[31]}}, id_inst[31:20]};
wire [31:0] id_imm_U = {id_inst[31:12], 12'b0};
wire [31:0] id_imm_S = {{20{id_inst[31]}}, id_inst[31:25], id_inst[11:7]};
wire [31:0] id_imm_B = {{20{id_inst[31]}}, id_inst[7], id_inst[30:25], id_inst[11:8], 1'b0};
wire [31:0] id_imm_J = {{12{id_inst[31]}}, id_inst[19:12], id_inst[20], id_inst[30:21], 1'b0};

wire [31:0] id_imm = (id_is_lui | id_is_auipc) ? id_imm_U :
                     (id_is_jal) ? id_imm_J :
                     (id_is_branch) ? id_imm_B :
                     (id_is_store) ? id_imm_S : id_imm_I;

wire id_rf_we = (id_is_lui | id_is_auipc | id_is_jal | id_is_jalr | id_is_load | id_is_imm | id_is_reg);

wire [31:0] id_rv1, id_rv2;
wire [31:0] debug_reg_rd_raw;
regfile u_regfile(
    .clk(clk),
    .raddr1(id_rs1), .rdata1(id_rv1),
    .raddr2(id_rs2), .rdata2(id_rv2),
    .raddr3(debug_reg_ra), .rdata3(debug_reg_rd_raw),
    .we(commit_reg_we), .waddr(commit_reg_wa), .wdata(commit_reg_wd)
);

// ID/EX Register Update
reg        ID_EX_is_jal, ID_EX_is_jalr;
reg        ID_EX_is_auipc, ID_EX_is_lui;
reg        ID_EX_is_sub, ID_EX_is_sra;
reg        ID_EX_is_add_forced;
reg        ID_EX_is_system;
reg        ID_EX_is_imm;
reg [6:0]  ID_EX_funct7;

always @(posedge clk) begin
    if (rst || flush_ID_EX) begin
        ID_EX_valid         <= 1'b0;
        ID_EX_pc            <= 32'b0;
        ID_EX_inst          <= 32'h00000013; // nop
        ID_EX_rv1           <= 32'b0;
        ID_EX_rv2           <= 32'b0;
        ID_EX_imm           <= 32'b0;
        ID_EX_rs1           <= 5'b0;
        ID_EX_rs2           <= 5'b0;
        ID_EX_rd            <= 5'b0;
        ID_EX_is_load       <= 1'b0;
        ID_EX_is_store      <= 1'b0;
        ID_EX_reg_we        <= 1'b0;
        ID_EX_funct3        <= 3'b0;
        ID_EX_funct7        <= 7'b0;
        ID_EX_is_jal        <= 1'b0;
        ID_EX_is_jalr       <= 1'b0;
        ID_EX_is_branch     <= 1'b0;
        ID_EX_is_auipc      <= 1'b0;
        ID_EX_is_lui        <= 1'b0;
        ID_EX_is_sub        <= 1'b0;
        ID_EX_is_sra        <= 1'b0;
        ID_EX_is_add_forced <= 1'b0;
        ID_EX_is_system     <= 1'b0;
        ID_EX_is_imm        <= 1'b0;
        ID_EX_pred_taken    <= 1'b0;
        ID_EX_pred_history  <= 2'b0;
        ID_EX_pred_ghr      <= 10'b0;
        ID_EX_pred_is_global<= 1'b0;
    end else if (global_en && valid && ID_EX_write && !div_stall) begin
        ID_EX_valid         <= IF_ID_valid;
        ID_EX_pc            <= IF_ID_pc;
        ID_EX_inst          <= IF_ID_inst;
        ID_EX_pred_taken    <= IF_ID_pred_taken;
        ID_EX_pred_history  <= IF_ID_pred_history;
        ID_EX_pred_ghr      <= IF_ID_pred_ghr;
        ID_EX_pred_is_global<= IF_ID_pred_is_global;
        ID_EX_rv1           <= id_rv1;
        ID_EX_rv2           <= id_rv2;
        ID_EX_imm           <= id_imm;
        ID_EX_rs1           <= id_rs1;
        ID_EX_rs2           <= id_rs2;
        ID_EX_rd            <= id_rd;
        ID_EX_is_load       <= id_is_load;
        ID_EX_is_store      <= id_is_store;
        ID_EX_reg_we        <= id_rf_we;
        ID_EX_funct3        <= id_funct3;
        ID_EX_funct7        <= id_funct7;
        ID_EX_is_jal        <= id_is_jal;
        ID_EX_is_jalr       <= id_is_jalr;
        ID_EX_is_branch     <= id_is_branch;
        ID_EX_is_auipc      <= id_is_auipc;
        ID_EX_is_lui        <= id_is_lui;
        ID_EX_is_sub        <= (id_opcode == 7'b0110011 && id_funct7[5]);
        ID_EX_is_sra        <= (id_funct3 == 3'b101 && id_funct7[5]);
        ID_EX_is_add_forced <= (id_is_auipc | id_is_load | id_is_store);
        ID_EX_is_system     <= id_is_system;
        ID_EX_is_imm        <= id_is_imm;
    end
end

// ==========================================
// Execute Stage (EX)
// ==========================================
wire [31:0] ex_fw_rv1 = rf_rd0_fe ? rf_rd0_fd : ID_EX_rv1;
wire [31:0] ex_fw_rv2 = rf_rd1_fe ? rf_rd1_fd : ID_EX_rv2;

wire [31:0] alu_src1 = (ID_EX_is_auipc | ID_EX_is_jal | ID_EX_is_branch) ? ID_EX_pc : ex_fw_rv1;
wire [31:0] alu_src2 = (ID_EX_is_lui | ID_EX_is_auipc | ID_EX_is_jal | ID_EX_is_branch | ID_EX_is_jalr | ID_EX_is_load | ID_EX_is_store | ID_EX_is_imm) ? ID_EX_imm : ex_fw_rv2;

wire [31:0] sub_res = alu_src1 - alu_src2;
wire [31:0] add_res = alu_src1 + alu_src2;
wire [31:0] sll_res = alu_src1 << alu_src2[4:0];
wire [31:0] srl_res = alu_src1 >> alu_src2[4:0];
wire [31:0] sra_res = $signed(alu_src1) >>> alu_src2[4:0];
wire slt_res = ($signed(alu_src1) < $signed(alu_src2));
wire sltu_res = (alu_src1 < alu_src2);
wire [31:0] xor_res = alu_src1 ^ alu_src2;
wire [31:0] or_res = alu_src1 | alu_src2;
wire [31:0] and_res = alu_src1 & alu_src2;

// RV32M: opcode 0110011 + funct7 0000001。funct3[2]==0 为乘法类，==1 为除法类。
wire ID_EX_is_m   = (ID_EX_inst[6:0] == 7'b0110011) && (ID_EX_funct7 == 7'b0000001);
wire ID_EX_is_mul = ID_EX_is_m && ~ID_EX_funct3[2];
wire ID_EX_is_div = ID_EX_is_m &&  ID_EX_funct3[2];

// 乘法：mulhu(funct3==011) 零扩展，mul/mulh 符号扩展到 33 位
wire [32:0] mul_src1 = (ID_EX_funct3 == 3'b011) ? {1'b0, ex_fw_rv1} : {ex_fw_rv1[31], ex_fw_rv1};
wire [32:0] mul_src2 = (ID_EX_funct3 == 3'b011) ? {1'b0, ex_fw_rv2} : {ex_fw_rv2[31], ex_fw_rv2};
wire [65:0] mul_res_66 = $signed(mul_src1) * $signed(mul_src2);
wire [31:0] final_mul_res = (ID_EX_funct3 == 3'b000) ? mul_res_66[31:0] : mul_res_66[63:32];

// 除法：funct3 100=div 101=divu 110=rem 111=remu。is_signed=~funct3[0]，funct3[1] 选商/余数
// 使用组合逻辑除法器
wire [31:0] div_q, div_r;
wire        div_in_ex = ID_EX_valid && ID_EX_is_div;
assign      div_done  = 1'b1; // 组合逻辑立即完成
assign      div_busy  = 1'b0;
assign      div_stall = 1'b0; // 组合逻辑不产生额外停顿
Div u_div(
    .a(ex_fw_rv1),
    .b(ex_fw_rv2),
    .is_signed(~ID_EX_funct3[0]),
    .quotient(div_q),
    .remainder(div_r)
);
wire [31:0] final_div_res = ID_EX_funct3[1] ? div_r : div_q;

wire [31:0] alu_res = (ID_EX_is_div) ? final_div_res :
                      (ID_EX_is_mul) ? final_mul_res :
                      (ID_EX_is_lui) ? alu_src2 :
                      (ID_EX_is_jal | ID_EX_is_jalr) ? (ID_EX_pc + 4) :
                      (ID_EX_is_add_forced) ? add_res :
                      (ID_EX_funct3 == 3'b000) ? (ID_EX_is_sub ? sub_res : add_res) :
                      (ID_EX_funct3 == 3'b001) ? sll_res :
                      (ID_EX_funct3 == 3'b010) ? {31'b0, slt_res} :
                      (ID_EX_funct3 == 3'b011) ? {31'b0, sltu_res} :
                      (ID_EX_funct3 == 3'b100) ? xor_res :
                      (ID_EX_funct3 == 3'b101) ? (ID_EX_is_sra ? sra_res : srl_res) :
                      (ID_EX_funct3 == 3'b110) ? or_res : and_res;

wire eq  = (ex_fw_rv1 == ex_fw_rv2);
wire lt  = ($signed(ex_fw_rv1) < $signed(ex_fw_rv2));
wire ltu = (ex_fw_rv1 < ex_fw_rv2);
wire comp_res = (ID_EX_funct3 == 3'b000) ? eq :
                (ID_EX_funct3 == 3'b001) ? !eq :
                (ID_EX_funct3 == 3'b100) ? lt :
                (ID_EX_funct3 == 3'b101) ? !lt :
                (ID_EX_funct3 == 3'b110) ? ltu : !ltu;

assign branch_taken = ID_EX_is_branch && comp_res;
assign jump_taken   = ID_EX_is_jal || ID_EX_is_jalr;
assign jump_branch_target = (ID_EX_is_jal || ID_EX_is_branch) ? (ID_EX_pc + ID_EX_imm) :
                            (ID_EX_is_jalr) ? ((ex_fw_rv1 + ID_EX_imm) & ~32'b1) :
                            (ID_EX_pc + 4);

reg EX_MEM_is_system;

// EX/MEM Register Update
always @(posedge clk) begin
    if (rst) begin
        EX_MEM_valid         <= 1'b0;
        EX_MEM_pc            <= 32'b0;
        EX_MEM_inst          <= 32'h00000013;
        EX_MEM_alu_res       <= 32'b0;
        EX_MEM_store_data    <= 32'b0;
        EX_MEM_rd            <= 5'b0;
        EX_MEM_reg_we        <= 1'b0;
        EX_MEM_dmem_we       <= 1'b0;
        EX_MEM_is_load       <= 1'b0;
        EX_MEM_funct3        <= 3'b0;
        EX_MEM_is_system     <= 1'b0;
    end else if (global_en && valid && EX_MEM_write) begin
        if (div_stall) begin
            // 除法计算期间向 EX/MEM 注入气泡，避免未就绪结果写回/访存
            EX_MEM_valid         <= 1'b0;
            EX_MEM_pc            <= ID_EX_pc;
            EX_MEM_inst          <= 32'h00000013; // nop
            EX_MEM_alu_res       <= 32'b0;
            EX_MEM_store_data    <= 32'b0;
            EX_MEM_rd            <= 5'b0;
            EX_MEM_reg_we        <= 1'b0;
            EX_MEM_dmem_we       <= 1'b0;
            EX_MEM_is_load       <= 1'b0;
            EX_MEM_funct3        <= 3'b0;
            EX_MEM_is_system     <= 1'b0;
        end else begin
            EX_MEM_valid         <= ID_EX_valid;
            EX_MEM_pc            <= ID_EX_pc;
            EX_MEM_inst          <= ID_EX_inst;
            EX_MEM_alu_res       <= alu_res;
            EX_MEM_store_data    <= ex_fw_rv2;
            EX_MEM_rd            <= ID_EX_rd;
            EX_MEM_reg_we        <= ID_EX_reg_we;
            EX_MEM_dmem_we       <= ID_EX_is_store;
            EX_MEM_is_load       <= ID_EX_is_load;
            EX_MEM_funct3        <= ID_EX_funct3;
            EX_MEM_is_system     <= ID_EX_is_system;
        end
    end
end

// ==========================================
// Memory Stage (MEM)
// ==========================================
assign dmem_addr = EX_MEM_alu_res;
assign dmem_we   = EX_MEM_dmem_we && valid && global_en;

wire [1:0] mem_offset = EX_MEM_alu_res[1:0];

// 根据 funct3 和 offset 生成字节掩码和对齐后的写数据
assign dmem_wmask = (EX_MEM_funct3 == 3'b000) ? (4'b0001 << mem_offset) :
                    (EX_MEM_funct3 == 3'b001) ? (4'b0011 << (mem_offset[1] ? 2 : 0)) : 
                    (EX_MEM_dmem_we ? 4'b1111 : 4'b0000);

assign dmem_wdata = (EX_MEM_funct3 == 3'b000) ? ({24'b0, EX_MEM_store_data[7:0]} << (mem_offset * 8)) :
                    (EX_MEM_funct3 == 3'b001) ? ({16'b0, EX_MEM_store_data[15:0]} << (mem_offset[1] * 16)) : 
                    EX_MEM_store_data;

assign dmem_re = EX_MEM_is_load && EX_MEM_valid && valid && global_en;

reg MEM_WB_is_system;

// MEM/WB Register Update
always @(posedge clk) begin
    if (rst) begin
        MEM_WB_valid         <= 1'b0;
        MEM_WB_pc            <= 32'b0;
        MEM_WB_inst          <= 32'h00000013;
        MEM_WB_alu_res       <= 32'b0;
        MEM_WB_load_data     <= 32'b0;
        MEM_WB_rd            <= 5'b0;
        MEM_WB_reg_we        <= 1'b0;
        MEM_WB_is_load       <= 1'b0;
        MEM_WB_funct3        <= 3'b0;
        MEM_WB_is_system     <= 1'b0;
        MEM_WB_dmem_we       <= 1'b0;
        MEM_WB_dmem_wa       <= 32'b0;
        MEM_WB_dmem_wd       <= 32'b0;
    end else if (global_en && valid && MEM_WB_write) begin
        MEM_WB_valid         <= EX_MEM_valid;
        MEM_WB_pc            <= EX_MEM_pc;
        MEM_WB_inst          <= EX_MEM_inst;
        MEM_WB_alu_res       <= EX_MEM_alu_res;
        MEM_WB_load_data     <= dmem_rdata; 
        MEM_WB_rd            <= EX_MEM_rd;
        MEM_WB_reg_we        <= EX_MEM_reg_we;
        MEM_WB_is_load       <= EX_MEM_is_load;
        MEM_WB_funct3        <= EX_MEM_funct3;
        MEM_WB_is_system     <= EX_MEM_is_system;
        MEM_WB_dmem_we       <= EX_MEM_dmem_we;
        MEM_WB_dmem_wa       <= EX_MEM_alu_res;
        MEM_WB_dmem_wd       <= EX_MEM_store_data;
    end
end

// ==========================================
// Write Back Stage (WB)
// ==========================================
wire [1:0] wb_offset = MEM_WB_alu_res[1:0];
wire [7:0] load_byte = (wb_offset == 2'b00) ? MEM_WB_load_data[7:0] :
                       (wb_offset == 2'b01) ? MEM_WB_load_data[15:8] :
                       (wb_offset == 2'b10) ? MEM_WB_load_data[23:16] :
                                              MEM_WB_load_data[31:24];

wire [15:0] load_half = (wb_offset[1] == 1'b0) ? MEM_WB_load_data[15:0] : MEM_WB_load_data[31:16];

wire [31:0] final_load_data = (MEM_WB_funct3 == 3'b000) ? {{24{load_byte[7]}}, load_byte} :
                              (MEM_WB_funct3 == 3'b001) ? {{16{load_half[15]}}, load_half} :
                              (MEM_WB_funct3 == 3'b010) ? MEM_WB_load_data :
                              (MEM_WB_funct3 == 3'b100) ? {24'b0, load_byte} :
                              (MEM_WB_funct3 == 3'b101) ? {16'b0, load_half} : MEM_WB_load_data;

// 生成对外围提供的 commit 提交信息
assign commit        = valid && global_en && MEM_WB_valid && MEM_WB_write;

always @(posedge clk) begin
end

assign commit_reg_wd = MEM_WB_is_load ? final_load_data : MEM_WB_alu_res;
assign commit_reg_we = MEM_WB_reg_we && commit;
assign commit_reg_wa = MEM_WB_rd;
assign commit_pc     = MEM_WB_pc;
assign commit_instr  = MEM_WB_inst;
assign commit_halt   = MEM_WB_is_system && (MEM_WB_inst == 32'h00100073) && commit;

assign commit_dmem_we = MEM_WB_dmem_we && commit;
assign commit_dmem_wa = MEM_WB_dmem_wa;
assign commit_dmem_wd = MEM_WB_dmem_wd;

assign debug_reg_rd = (commit_reg_we && (commit_reg_wa == debug_reg_ra) && (debug_reg_ra != 5'd0)) ? commit_reg_wd : debug_reg_rd_raw;

// ==========================================
// 冒险控制单元 (Hazard Unit)
// ==========================================
wire ID_EX_write, EX_MEM_write, MEM_WB_write;

HazardUnit u_hazard(
    .rf_ra0_id(id_rs1),
    .rf_ra1_id(id_rs2),
    .rf_wa_ex(ID_EX_rd),
    .rf_we_ex(ID_EX_reg_we),
    .rf_wd_sel_ex(ID_EX_is_load),
    .npc_sel_ex(pred_mismatch || jump_taken),
    .cache_miss(cache_miss),
    .mem_is_load(EX_MEM_is_load),
    .mem_is_store(EX_MEM_dmem_we),
    .PC_write(PC_write),
    .IF_ID_write(IF_ID_write),
    .ID_EX_write(ID_EX_write),
    .EX_MEM_write(EX_MEM_write),
    .MEM_WB_write(MEM_WB_write),
    .stall(stall),
    .flush_IF_ID(flush_IF_ID),
    .flush_ID_EX(flush_ID_EX)
);

// ==========================================
// 前递单元 (Forwarding Unit)
// ==========================================
wire        rf_rd0_fe, rf_rd1_fe;
wire [31:0] rf_rd0_fd, rf_rd1_fd;
ForwardingUnit u_forward(
    .rf_ra0_ex(ID_EX_rs1),
    .rf_ra1_ex(ID_EX_rs2),
    .rf_wa_mem(EX_MEM_rd),
    .rf_we_mem(EX_MEM_reg_we),
    .rf_wd_mem(EX_MEM_alu_res),
    .rf_wa_wb(MEM_WB_rd),
    .rf_we_wb(MEM_WB_reg_we),
    .rf_wd_wb(commit_reg_wd),
    .rf_rd0_fe(rf_rd0_fe),
    .rf_rd0_fd(rf_rd0_fd),
    .rf_rd1_fe(rf_rd1_fe),
    .rf_rd1_fd(rf_rd1_fd)
);


reg [31:0] total_branches;
reg [31:0] bpu_hits;
always @(posedge clk) begin
    if (rst) begin
        total_branches <= 0;
        bpu_hits <= 0;
    end else if (global_en && valid && ID_EX_is_branch) begin
        total_branches <= total_branches + 1;
        if (!pred_mismatch) bpu_hits <= bpu_hits + 1;
    end
end
always @(negedge clk) begin
    if (commit_halt && commit) begin
        $display("BPU Stats: Total Branches: %0d, Hits: %0d", total_branches, bpu_hits);
    end
end

endmodule



