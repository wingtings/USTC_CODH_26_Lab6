`timescale 1ns / 1ps

// 混合分支预测器：全局预测 + 局部预测 + 竞争选择器

module BranchPredictor (
    input  wire        clk,
    input  wire        rst,
    
    // 预测阶段 (IF)
    input  wire [31:0] pc_if,                    // IF 阶段 PC
    output wire        pred_taken,               // 预测分支是否跳转
    output wire [ 1:0] pred_history,             // 当前预测所用的历史信息
    output wire [ 9:0] pred_ghr,                 // 预测时的全局历史
    
    // 更新阶段 (EX)
    input  wire [31:0] pc_ex,                    // EX 阶段 PC
    input  wire        is_branch_ex,             // 是否为分支指令
    input  wire        actual_taken,             // 实际分支结果
    input  wire        pred_wrong,               // 预测是否错误
    input  wire [ 1:0] pred_history_ex,          // 预测时的历史信息
    input  wire [ 9:0] pred_ghr_ex,              // 预测时的全局历史
    input  wire        pred_is_global_ex         // 预测时是否选择全局预测
);

    // 全局预测器组件 (Global Predictor)
    
    // 全局历史寄存器 (GHR) - 10位，记录最近10个分支结果
    reg [9:0] ghr;
    
    // 全局预测表 (GPT) - 2K条目，每条2位计数器
    reg [1:0] gpt [1023:0];
    
    wire [9:0] gpt_idx_pred = ghr;
    wire [9:0] gpt_idx_upd  = pred_ghr_ex;
    wire [1:0] counter_global_pred = gpt[gpt_idx_pred];
    wire       global_pred = counter_global_pred[1];  // 计数器 >= 2 时预测跳转
    
    // 局部预测器组件 (BHT+PHT)
    
    // BHT (Branch History Table)
    reg [1:0] bht [255:0];
    
    wire [7:0] bht_idx_if = pc_if[9:2];
    wire [7:0] bht_idx_ex = pc_ex[9:2];
    
    wire [1:0] curr_history = bht[bht_idx_if];
    
    // PHT (Pattern History Table)
    reg [1:0] pht [511:0];
    
    wire [8:0] pht_idx_pred = {bht_idx_if, curr_history};
    wire [8:0] pht_idx_upd  = {bht_idx_ex, pred_history_ex};
    
    wire [1:0] counter_local_pred = pht[pht_idx_pred];
    wire       local_pred = counter_local_pred[1];
    
    // 竞争选择器组件 (Meta Predictor / Selector)
    
    // 选择器表 (Selector Table) - 1K条目，每条2位竞争计数器
    // 竞争计数器: >= 2时选择全局预测，< 2时选择局部预测
    reg [1:0] selector [1023:0];
    
    wire [9:0] selector_idx_pred = ghr;
    wire [9:0] selector_idx_upd  = pred_ghr_ex;
    wire [1:0] selector_counter  = selector[selector_idx_pred];
    wire       use_global = selector_counter[1];
    
    wire final_pred = use_global ? global_pred : local_pred;
    
    // 预测阶段输出
    
    assign pred_taken   = final_pred;
    assign pred_history = curr_history;
    assign pred_ghr     = ghr;
    
    // 实时修正与更新逻辑 (Real-time Correction & Update)
    
    wire global_correct = (global_pred == actual_taken);
    wire local_correct  = (local_pred == actual_taken);
    wire selector_agrees_with_actual = (final_pred == actual_taken);
    
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            // 初始化
            integer i;
            for (i = 0; i < 256; i = i + 1)
                bht[i] <= 2'b01;
            for (i = 0; i < 512; i = i + 1)
                pht[i] <= 2'b01;
            for (i = 0; i < 1024; i = i + 1)
                gpt[i] <= 2'b01;
            for (i = 0; i < 1024; i = i + 1)
                selector[i] <= 2'b01;  // 初始化为弱偏向局部预测
        end else if (is_branch_ex) begin
            
            // 全局预测表 (GPT) 更新
            if (actual_taken) begin
                // 分支跳转：计数器加 1，最大 3
                if (gpt[gpt_idx_upd] != 2'b11)
                    gpt[gpt_idx_upd] <= gpt[gpt_idx_upd] + 1'b1;
            end else begin
                // 分支不跳转：计数器减 1，最小 0
                if (gpt[gpt_idx_upd] != 2'b00)
                    gpt[gpt_idx_upd] <= gpt[gpt_idx_upd] - 1'b1;
            end
            
            // 2. 局部预测表 (PHT) 更新
            if (actual_taken) begin
                if (pht[pht_idx_upd] != 2'b11)
                    pht[pht_idx_upd] <= pht[pht_idx_upd] + 1'b1;
            end else begin
                if (pht[pht_idx_upd] != 2'b00)
                    pht[pht_idx_upd] <= pht[pht_idx_upd] - 1'b1;
            end
            
            // 3. 竞争选择器 (Selector) 更新
            //    - 当两个预测器给出不同预测时更新选择器
            //    - 增强/减弱对赢者预测器的偏好
            if (pred_is_global_ex) begin
                // 当前选择的是全局预测
                if (global_correct && !local_correct) begin
                    // 全局正确，局部错误 -> 增强全局偏好
                    if (selector[selector_idx_upd] != 2'b11)
                        selector[selector_idx_upd] <= selector[selector_idx_upd] + 1'b1;
                end else if (!global_correct && local_correct) begin
                    // 全局错误，局部正确 -> 削弱全局偏好
                    if (selector[selector_idx_upd] != 2'b00)
                        selector[selector_idx_upd] <= selector[selector_idx_upd] - 1'b1;
                end
            end else begin
                // 当前选择的是局部预测
                if (local_correct && !global_correct) begin
                    // 局部正确，全局错误 -> 增强局部偏好（减少全局偏好）
                    if (selector[selector_idx_upd] != 2'b00)
                        selector[selector_idx_upd] <= selector[selector_idx_upd] - 1'b1;
                end else if (!local_correct && global_correct) begin
                    // 局部错误，全局正确 -> 削弱局部偏好（增强全局偏好）
                    if (selector[selector_idx_upd] != 2'b11)
                        selector[selector_idx_upd] <= selector[selector_idx_upd] + 1'b1;
                end
            end
            
            // 4. 分支历史表 (BHT) 更新 - 使用实际结果
            bht[bht_idx_ex] <= {pred_history_ex[0], actual_taken};
            
            // 5. 全局历史寄存器 (GHR) 更新 - 使用实际结果
            ghr <= {ghr[8:0], actual_taken};
            
        end
    end

endmodule
