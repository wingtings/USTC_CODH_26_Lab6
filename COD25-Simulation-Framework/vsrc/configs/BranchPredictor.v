`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: BranchPredictor
// Description: 竞争式(Tournament)分支预测器 = 局部预测 + 全局预测 + 竞争选择器
//   局部预测：BHT(256x2bit 局部历史) + PHT(512x2bit 计数器)，索引 {pc[9:2], 局部历史}
//   全局预测：GHR(10bit 全局历史) + GPT(1024x2bit 计数器)，索引 GHR
//   竞争选择：sel(1024x2bit)，由 GHR 索引；高位=1 选全局，=0 选局部
//   预测在 IF 阶段(组合)给出，验证与更新在 EX 阶段(用流水线传下来的索引)进行。
//////////////////////////////////////////////////////////////////////////////////

module BranchPredictor (
    input  wire        clk,
    input  wire        rst,

    // 预测阶段 (IF)
    input  wire [31:0] pc_if,
    output wire        pred_taken,        // 最终预测（局部或全局）
    output wire [ 1:0] pred_history,      // 本次所用的局部历史
    output wire [ 9:0] pred_ghr,          // 本次所用的全局历史
    output wire        pred_is_global,    // 本次选择器选了全局(1)还是局部(0)

    // 更新阶段 (EX)
    input  wire [31:0] pc_ex,
    input  wire        is_branch_ex,
    input  wire        actual_taken,
    input  wire        pred_wrong,
    input  wire [ 1:0] pred_history_ex,   // 预测时的局部历史
    input  wire [ 9:0] pred_ghr_ex,       // 预测时的全局历史
    input  wire        pred_is_global_ex  // 预测时选择器的选择
);

    // ---- 存储结构 ----
    reg [1:0] bht [255:0];     // 局部历史表
    reg [1:0] pht [1023:0];    // 局部模式表
    reg [9:0] ghr;             // 全局历史寄存器
    reg [1:0] gpt [1023:0];    // 全局模式表
    reg [1:0] sel [1023:0];    // 竞争选择器表

    // ---- IF: 并行三路预测 ----
    wire [7:0] bidx_if    = pc_if[9:2];
    wire [1:0] lhist_if   = bht[bidx_if];
    wire [9:0] pht_idx_if = {bidx_if, lhist_if};

    wire local_pred  = pht[pht_idx_if][1];
    wire global_pred = gpt[ghr][1];
    wire use_global  = sel[ghr][1];

    assign pred_taken     = use_global ? global_pred : local_pred;
    assign pred_history   = lhist_if;
    assign pred_ghr       = ghr;
    assign pred_is_global = use_global;

    // ---- EX: 用保存的索引重算两路预测，作为选择器更新依据 ----
    wire [7:0] bidx_ex    = pc_ex[9:2];
    wire [9:0] pht_idx_ex = {bidx_ex, pred_history_ex};
    wire local_pred_ex    = pht[pht_idx_ex][1];
    wire global_pred_ex   = gpt[pred_ghr_ex][1];
    wire local_correct    = (local_pred_ex  == actual_taken);
    wire global_correct   = (global_pred_ex == actual_taken);

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 256;  i = i + 1) bht[i] = 2'b01;
            for (i = 0; i < 1024; i = i + 1) pht[i] = 2'b01;
            for (i = 0; i < 1024; i = i + 1) gpt[i] = 2'b01;
            for (i = 0; i < 1024; i = i + 1) sel[i] = 2'b01;
            ghr <= 10'b0;
        end else if (is_branch_ex) begin
            // 1) 局部 PHT 饱和计数器更新
            if (actual_taken) begin
                if (pht[pht_idx_ex] != 2'b11) pht[pht_idx_ex] <= pht[pht_idx_ex] + 1'b1;
            end else begin
                if (pht[pht_idx_ex] != 2'b00) pht[pht_idx_ex] <= pht[pht_idx_ex] - 1'b1;
            end
            // 2) 局部 BHT 历史移位
            bht[bidx_ex] <= {pred_history_ex[0], actual_taken};
            // 3) 全局 GPT 饱和计数器更新（用预测时的 GHR 索引）
            if (actual_taken) begin
                if (gpt[pred_ghr_ex] != 2'b11) gpt[pred_ghr_ex] <= gpt[pred_ghr_ex] + 1'b1;
            end else begin
                if (gpt[pred_ghr_ex] != 2'b00) gpt[pred_ghr_ex] <= gpt[pred_ghr_ex] - 1'b1;
            end
            // 4) 竞争选择器：谁正确就偏向谁（高位=全局）
            if (global_correct & ~local_correct) begin
                if (sel[pred_ghr_ex] != 2'b11) sel[pred_ghr_ex] <= sel[pred_ghr_ex] + 1'b1;
            end else if (~global_correct & local_correct) begin
                if (sel[pred_ghr_ex] != 2'b00) sel[pred_ghr_ex] <= sel[pred_ghr_ex] - 1'b1;
            end
            // 5) 全局历史寄存器用实际结果更新
            ghr <= {ghr[8:0], actual_taken};
        end
    end

endmodule

