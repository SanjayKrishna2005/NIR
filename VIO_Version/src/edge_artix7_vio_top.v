// =============================================================================
// File Name   : edge_artix7_vio_top.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
`timescale 1ns / 1ps

module edge_artix7_vio_top (
    input  wire clk,         // Main clock from N11 pin
    input  wire [0:0] pb     // Physical push button from K13
);

    wire clk100;
    wire mmcm_locked;

    // 1. Clocking Wizard (Input freq -> 100 MHz)
    // NOTE: When generating this IP, make sure to set the primary input clock
    // frequency to whatever the EDGE Artix-7 oscillator is (e.g., 50 MHz or 100 MHz).
    clk_wiz_0 u_clk_wiz (
        .clk_in1  (clk),          // Clock coming in from N11
        .clk_out1 (clk100),       // 100 MHz going out to our design
        .reset    (1'b0),         // Never reset the clock wizard itself
        .locked   (mmcm_locked)   // Goes HIGH when the 100 MHz clock is stable
    );

    // 2. Safe Reset Logic
    reg rst_n_meta, rst_n_sync;
    always @(posedge clk100) begin
        // If pb is pressed OR the clock isn't stable yet, hold reset low
        // NOTE: If pb[0] is active-high, we invert it.
        rst_n_meta <= (~pb[0]) & mmcm_locked; 
        rst_n_sync <= rst_n_meta;
    end

    // 3. Instantiate the VIO Hardware Testbench
    vio_hardware_testbench u_testbench (
        .clk   (clk100),
        .rst_n (rst_n_sync)
    );

endmodule
