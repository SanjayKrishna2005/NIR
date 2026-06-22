// =============================================================================
// File Name   : preprocess_top.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module preprocess_top (
    input  wire        clk,
    input  wire        rst,

    // Configuration — hold stable during spectrum processing
    input  wire        mode_filter,   // 0=MA  1=SG
    input  wire [7:0]  scale_in,      // quantiser scale (default 110)
    input  wire        scale_we,      // pulse 1 cycle to update scale

    // Input: raw 16-bit ADC, 224 samples
    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,

    // Output: INT8 signed, 224 samples
    output wire        m_valid,
    output wire [7:0]  m_data,
    output wire        m_last
);

    // Stage wires: dark_correct -> baseline_correct
    wire        dc_valid, dc_last;
    wire [15:0] dc_data;

    // Stage wires: baseline_correct -> filter_stage
    wire        bc_valid, bc_last;
    wire [15:0] bc_data;

    // Stage wires: filter_stage -> snv_norm
    wire        flt_valid, flt_last;
    wire [15:0] flt_data;

    // Stage wires: snv_norm -> quantiser
    wire        snv_valid, snv_last;
    wire [15:0] snv_data;

    // Stage 0: dark current subtraction  [NEW]
    dark_correct u_dark (
        .clk    (clk),
        .rst    (rst),
        .s_valid(s_valid),
        .s_data (s_data),
        .s_last (s_last),
        .m_valid(dc_valid),
        .m_data (dc_data),
        .m_last (dc_last)
    );

    // Stage 1: baseline correction
    baseline_correct u_baseline (
        .clk    (clk),
        .rst    (rst),
        .s_valid(dc_valid),
        .s_data (dc_data),
        .s_last (dc_last),
        .m_valid(bc_valid),
        .m_data (bc_data),
        .m_last (bc_last)
    );

    // Stage 2: smoothing filter (MA or SG)
    filter_stage u_filter (
        .clk    (clk),
        .rst    (rst),
        .mode   (mode_filter),
        .s_valid(bc_valid),
        .s_data (bc_data),
        .s_last (bc_last),
        .m_valid(flt_valid),
        .m_data (flt_data),
        .m_last (flt_last)
    );

    // Stage 3: SNV normalisation
    snv_norm u_snv (
        .clk    (clk),
        .rst    (rst),
        .s_valid(flt_valid),
        .s_data (flt_data),
        .s_last (flt_last),
        .m_valid(snv_valid),
        .m_data (snv_data),
        .m_last (snv_last)
    );

    // Stage 4: quantiser  Q8.8 -> INT8
    quantiser u_quant (
        .clk     (clk),
        .rst     (rst),
        .scale_in(scale_in),
        .scale_we(scale_we),
        .s_valid (snv_valid),
        .s_data  (snv_data),
        .s_last  (snv_last),
        .m_valid (m_valid),
        .m_data  (m_data),
        .m_last  (m_last)
    );

endmodule