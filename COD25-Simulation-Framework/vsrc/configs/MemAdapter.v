`timescale 1ns / 1ps
module MemAdapter (
    input  wire         clk,
    input  wire         rst,
    // Cache interface
    input  wire         mem_r,
    input  wire         mem_w,
    input  wire [31:0]  mem_addr,
    input  wire [127:0] mem_w_data,
    output reg  [127:0] mem_r_data,
    output reg          mem_ready,
    // Physical Memory interface (32-bit)
    output reg  [31:0]  phy_mem_addr,
    output reg  [31:0]  phy_mem_wdata,
    input  wire [31:0]  phy_mem_rdata,
    output reg          phy_mem_we
);

    reg [3:0] state;
    localparam IDLE = 4'd0;
    localparam R0 = 4'd1, R1 = 4'd2, R2 = 4'd3, R3 = 4'd4, R4 = 4'd5;
    localparam W0 = 4'd6, W1 = 4'd7, W2 = 4'd8, W3 = 4'd9, W_DONE = 4'd10;

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            mem_ready <= 1'b0;
            phy_mem_we <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    mem_ready <= 1'b0;
                    if (mem_r) begin
                        state <= R0;
                        phy_mem_addr <= {mem_addr[31:4], 4'b0000};
                        phy_mem_we <= 1'b0;
                    end else if (mem_w) begin
                        state <= W0;
                        phy_mem_addr <= {mem_addr[31:4], 4'b0000};
                        phy_mem_wdata <= mem_w_data[31:0];
                        phy_mem_we <= 1'b1;
                    end
                end
                
                // Read: 4 words. Each word takes 1 cycle (BRAM latency).
                R0: begin phy_mem_addr <= {mem_addr[31:4], 4'b0100}; state <= R1; end
                R1: begin phy_mem_addr <= {mem_addr[31:4], 4'b1000}; mem_r_data[31:0] <= phy_mem_rdata; state <= R2; end
                R2: begin phy_mem_addr <= {mem_addr[31:4], 4'b1100}; mem_r_data[63:32] <= phy_mem_rdata; state <= R3; end
                R3: begin mem_r_data[95:64] <= phy_mem_rdata; state <= R4; end
                R4: begin mem_r_data[127:96] <= phy_mem_rdata; mem_ready <= 1'b1; state <= IDLE; end
                
                // Write: 4 words.
                W0: begin phy_mem_addr <= {mem_addr[31:4], 4'b0100}; phy_mem_wdata <= mem_w_data[63:32]; state <= W1; end
                W1: begin phy_mem_addr <= {mem_addr[31:4], 4'b1000}; phy_mem_wdata <= mem_w_data[95:64]; state <= W2; end
                W2: begin phy_mem_addr <= {mem_addr[31:4], 4'b1100}; phy_mem_wdata <= mem_w_data[127:96]; state <= W3; end
                W3: begin phy_mem_we <= 1'b0; state <= W_DONE; end
                W_DONE: begin mem_ready <= 1'b1; state <= IDLE; end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule

