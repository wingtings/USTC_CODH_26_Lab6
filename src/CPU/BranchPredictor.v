`timescale 1ns / 1ps

//两级自适应分支预测器：BHT + PHT
module BranchPredictor (
    input  wire        clk,
    input  wire        rst,
    
    // 预测阶段 (IF)
    input  wire [31:0] pc_if,                    // IF 阶段 PC
    output wire        pred_taken,               // 预测分支是否跳转
    output wire [ 1:0] pred_history,             // 当前预测所用的历史信息
    
    // 更新阶段 (EX)
    input  wire [31:0] pc_ex,                    // EX 阶段 PC
    input  wire        is_branch_ex,             // 是否为分支指令
    input  wire        actual_taken,             // 实际分支结果
    input  wire        pred_wrong,               // 预测是否错误
    input  wire [ 1:0] pred_history_ex           // 预测时的历史信息
);


    // BHT (Branch History Table)
    reg [1:0] bht [255:0];
    
    wire [7:0] bht_idx_if = pc_if[9:2];
    wire [7:0] bht_idx_ex = pc_ex[9:2];
    
    wire [1:0] curr_history = bht[bht_idx_if];
    
    // PHT (Pattern History Table)
    reg [1:0] pht [511:0];
    
    // 预测索引: PC[9:2] 直接连接到高位，历史连接到低位
    wire [8:0] pht_idx_pred = {bht_idx_if, curr_history};
    wire [8:0] pht_idx_upd  = {bht_idx_ex, pred_history_ex};
    
    wire [1:0] counter_pred = pht[pht_idx_pred];
    
    // 分支预测: 计数器 >= 2 时预测跳转
    assign pred_taken   = counter_pred[1];
    assign pred_history = curr_history;
    
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            // 初始化
            for (i = 0; i < 256; i = i + 1)
                bht[i] <= 2'b01;
            for (i = 0; i < 512; i = i + 1)
                pht[i] <= 2'b01;
        end else if (is_branch_ex) begin
            // 更新 PHT 计数器
            if (actual_taken) begin
                // 分支跳转：计数器加 1，最大 3
                if (pht[pht_idx_upd] != 2'b11)
                    pht[pht_idx_upd] <= pht[pht_idx_upd] + 1'b1;
            end else begin
                // 分支不跳转：计数器减 1，最小 0
                if (pht[pht_idx_upd] != 2'b00)
                    pht[pht_idx_upd] <= pht[pht_idx_upd] - 1'b1;
            end
            
            // 更新 BHT: 右移历史，加入新的预测结果
            // 新历史 = {旧历史[1], 实际结果}
            bht[bht_idx_ex] <= {pred_history_ex[0], actual_taken};
        end
    end

endmodule
