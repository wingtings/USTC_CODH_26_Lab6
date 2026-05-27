`timescale 1ns / 1ps
module ForwardingUnit(
    input  wire [ 4:0] rf_ra0_ex,
    input  wire [ 4:0] rf_ra1_ex,
    input  wire [ 4:0] rf_wa_mem,
    input  wire        rf_we_mem,
    input  wire [31:0] rf_wd_mem,
    input  wire [ 4:0] rf_wa_wb,
    input  wire        rf_we_wb,
    input  wire [31:0] rf_wd_wb,

    output wire        rf_rd0_fe,
    output wire [31:0] rf_rd0_fd,
    output wire        rf_rd1_fe,
    output wire [31:0] rf_rd1_fd
);

    // Forwarding for rs1
    assign rf_rd0_fe = (rf_we_mem && (rf_wa_mem != 0) && (rf_wa_mem == rf_ra0_ex)) || 
                       (rf_we_wb  && (rf_wa_wb  != 0) && (rf_wa_wb  == rf_ra0_ex));
    
    assign rf_rd0_fd = (rf_we_mem && (rf_wa_mem != 0) && (rf_wa_mem == rf_ra0_ex)) ? rf_wd_mem :
                       (rf_we_wb  && (rf_wa_wb  != 0) && (rf_wa_wb  == rf_ra0_ex)) ? rf_wd_wb : 32'b0;

    // Forwarding for rs2
    assign rf_rd1_fe = (rf_we_mem && (rf_wa_mem != 0) && (rf_wa_mem == rf_ra1_ex)) || 
                       (rf_we_wb  && (rf_wa_wb  != 0) && (rf_wa_wb  == rf_ra1_ex));
                       
    assign rf_rd1_fd = (rf_we_mem && (rf_wa_mem != 0) && (rf_wa_mem == rf_ra1_ex)) ? rf_wd_mem :
                       (rf_we_wb  && (rf_wa_wb  != 0) && (rf_wa_wb  == rf_ra1_ex)) ? rf_wd_wb : 32'b0;

endmodule
