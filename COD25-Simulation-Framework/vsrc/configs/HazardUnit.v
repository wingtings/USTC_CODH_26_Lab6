`timescale 1ns / 1ps
module HazardUnit(
    input  wire [ 4:0] rf_ra0_id,
    input  wire [ 4:0] rf_ra1_id,
    input  wire [ 4:0] rf_wa_ex,
    input  wire        rf_we_ex,
    input  wire        rf_wd_sel_ex,
    input  wire        npc_sel_ex,
    input  wire        cache_miss,      // Cache miss signal
    input  wire        mem_is_load,     // MEM stage is load
    input  wire        mem_is_store,    // MEM stage is store
    output wire        PC_write,
    output wire        IF_ID_write,
    output wire        ID_EX_write,     // New: control ID/EX update
    output wire        EX_MEM_write,    // New: control EX/MEM update
    output wire        MEM_WB_write,    // New: control MEM/WB update
    output wire        stall,
    output wire        flush_IF_ID,
    output wire        flush_ID_EX
);

    wire load_use_hazard = rf_we_ex && rf_wd_sel_ex && (rf_wa_ex != 0) &&
                           ((rf_wa_ex == rf_ra0_id) || (rf_wa_ex == rf_ra1_id));

    // mem_stall: In MEM stage, if miss occurs, we must stall.
    // Also, per the requirement "Even hit has 1 cycle latency", we need a handshake.
    // Let's assume cache_miss is 1 until hit/refill is confirmed.
    wire mem_stall = (mem_is_load || mem_is_store) && cache_miss;

    assign stall        = load_use_hazard || mem_stall;
    assign PC_write     = ~stall;
    assign IF_ID_write  = ~stall;
    assign ID_EX_write  = ~stall;
    assign EX_MEM_write = ~stall;
    assign MEM_WB_write = ~stall;
    
    wire control_hazard = npc_sel_ex;
    
    // IF/ID is flushed on branch/jump (control hazard)
    assign flush_IF_ID = control_hazard;
    
    // ID/EX is flushed on load-use stall (bubble) or control hazard
    // Note: mem_stall shouldn't flush ID/EX because we are freezing the whole pipe.
    assign flush_ID_EX = (load_use_hazard && !mem_stall) || control_hazard;

endmodule

