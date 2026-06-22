// =============================================================================
// File Name   : feature_buffer.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module feature_buffer #(
    parameter FEATURE_COUNT = 224,
    parameter ADDR_W        = 8
)(
    input  wire                 clk,
    input  wire                 rst,

    // Write side from preprocess_top
    input  wire                 s_valid,
    input  wire signed [7:0]    s_data,
    input  wire                 s_last,

    // Consume pulse from controller after a frame has been accepted
    input  wire                 consume,

    // Random-access read side for the SVM
    input  wire [ADDR_W-1:0]    r_addr,
    output reg  signed [7:0]    r_data,

    output reg                  frame_ready,
    output reg                  frame_full,
    output reg [ADDR_W-1:0]    wr_ptr
);

    reg signed [7:0] mem [0:FEATURE_COUNT-1];

    integer i;

    always @(posedge clk) begin
        if (rst) begin
            frame_ready <= 1'b0;
            frame_full  <= 1'b0;
            wr_ptr      <= {ADDR_W{1'b0}};
        end else begin
            if (consume) begin
                frame_ready <= 1'b0;
                frame_full  <= 1'b0;
                wr_ptr      <= {ADDR_W{1'b0}};
            end

            if (s_valid && !frame_full) begin
                mem[wr_ptr] <= s_data;

                if (s_last || (wr_ptr == FEATURE_COUNT-1)) begin
                    frame_ready <= 1'b1;
                    frame_full  <= 1'b1;
                    wr_ptr      <= {ADDR_W{1'b0}};
                end else begin
                    wr_ptr <= wr_ptr + {{(ADDR_W-1){1'b0}},1'b1};
                end
            end
        end
    end

    always @* begin
        if (r_addr < FEATURE_COUNT)
            r_data = mem[r_addr];
        else
            r_data = 8'sd0;
    end

endmodule
