// =============================================================================
// File Name   : svm_mac.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
(* use_dsp = "no" *)
module svm_mac(
    input  wire signed [7:0]   feature,
    input  wire signed [15:0]  weight,
    output wire signed [23:0]  product
);
    assign product = feature * weight;
endmodule
