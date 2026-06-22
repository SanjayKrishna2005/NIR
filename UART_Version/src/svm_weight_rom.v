// =============================================================================
// File Name   : svm_weight_rom.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module svm_weight_rom #(
    parameter WEIGHT_COUNT = 1120,
    parameter ADDR_W       = 11
)(
    input  wire [ADDR_W-1:0]  rd_addr,
    output reg signed [15:0]   rd_data
);

    reg signed [15:0] mem [0:WEIGHT_COUNT-1];

    initial begin
        $readmemh("weights.hex", mem);
    end

    always @* begin
        if (rd_addr < WEIGHT_COUNT)
            rd_data = mem[rd_addr];
        else
            rd_data = 16'sd0;
    end

endmodule
