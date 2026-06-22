// =============================================================================
// File Name   : edge_artix7_uart_top.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
`timescale 1ns / 1ps

module edge_artix7_uart_top (
    input  wire clk,         // Main clock from N11 pin
    input  wire [0:0] pb,    // Physical push button from K13
    input  wire uart_rx,     // USB UART RX (Pin D4)
    output wire uart_tx      // USB UART TX (Pin C4)
);

    // 100 MHz / 115200 = 868
    localparam CLKS_PER_BIT = 868; 

    wire clk100;
    wire mmcm_locked;

    // 1. Clocking Wizard (50 MHz -> 100 MHz)
    clk_wiz_0 u_clk_wiz (
        .clk_in1  (clk),          
        .clk_out1 (clk100),       
        .reset    (1'b0),         
        .locked   (mmcm_locked)   
    );

    // 2. Safe Reset Logic
    reg rst_n_meta, rst_n_sync;
    always @(posedge clk100) begin
        // pb[0] is pulled down (active high when pressed)
        rst_n_meta <= (~pb[0]) & mmcm_locked; 
        rst_n_sync <= rst_n_meta;
    end

    // 3. UART Top Module
    nir_sorter_uart_top #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_sorter (
        .clk        (clk100),
        .rst_n      (rst_n_sync),
        .uart_rx_in (uart_rx),
        .uart_tx_out(uart_tx),
        .mode_filter(1'b1),
        .scale_in   (8'd110),
        .scale_we   (1'b0)
    );

endmodule
