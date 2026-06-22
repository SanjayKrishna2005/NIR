// =============================================================================
// File Name   : svm_bias_rom.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module svm_bias_rom #(
    parameter CLASS_COUNT = 5,
    parameter ADDR_W      = 3
)(
    input  wire [ADDR_W-1:0]  rd_addr,
    output reg signed [31:0]   rd_data
);

    reg signed [31:0] mem [0:CLASS_COUNT-1];

    initial begin
        $readmemh("biases.hex", mem);
    end

    always @* begin
        if (rd_addr < CLASS_COUNT)
            rd_data = mem[rd_addr];
        else
            rd_data = 32'sd0;
    end

endmodule
