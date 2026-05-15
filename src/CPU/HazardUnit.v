`timescale 1ns / 1ps
module HazardUnit(
    input  wire [ 4:0] rf_ra0_id,
    input  wire [ 4:0] rf_ra1_id,
    input  wire [ 4:0] rf_wa_ex,
    input  wire        rf_we_ex,
    input  wire        rf_wd_sel_ex,
    input  wire        npc_sel_ex,
    output wire        PC_write,
    output wire        IF_ID_write,
    output wire        stall,
    output wire        flush_IF_ID,
    output wire        flush_ID_EX
);

    wire load_use_hazard = rf_we_ex && rf_wd_sel_ex && (rf_wa_ex != 0) &&
                           ((rf_wa_ex == rf_ra0_id) || (rf_wa_ex == rf_ra1_id));

    assign stall       = load_use_hazard;
    assign PC_write    = ~stall;
    assign IF_ID_write = ~stall;
    
    wire control_hazard = npc_sel_ex;
    
    // IF/ID is flushed on branch/jump (control hazard)
    assign flush_IF_ID = control_hazard;
    
    // ID/EX is flushed on stall (load-use) or control hazard
    assign flush_ID_EX = stall || control_hazard;

endmodule
