// =============================================================================
// File Name   : quantiser.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module quantiser (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  scale_in,
    input  wire        scale_we,
    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,
    output reg         m_valid,
    output reg  [7:0]  m_data,
    output reg         m_last
);

    // Scale register - default 110 (was 42)
    reg [7:0] scale;

    always @(posedge clk) begin
        if (rst)           scale <= 8'd110;
        else if (scale_we) scale <= scale_in;
    end

    // -------------------------------------------------------------------------
    // PIPELINE STAGE 1: Multiplication
    // -------------------------------------------------------------------------
    reg signed [23:0] product_reg;
    reg               s_valid_reg;
    reg               s_last_reg;

    always @(posedge clk) begin
        if (rst) begin
            product_reg <= 24'd0;
            s_valid_reg <= 1'b0;
            s_last_reg  <= 1'b0;
        end else begin
            product_reg <= $signed(s_data) * $signed({1'b0, scale});
            s_valid_reg <= s_valid;
            s_last_reg  <= s_last;
        end
    end

    // -------------------------------------------------------------------------
    // PIPELINE STAGE 2: Shift, Clamp, and Output
    // -------------------------------------------------------------------------
    wire signed [23:0] shifted = product_reg >>> 8;

    wire signed [7:0] clamped =
        ($signed(shifted) > 24'sd127)  ?  8'sd127 :
        ($signed(shifted) < -24'sd128) ? -8'sd128 :
        shifted[7:0];

    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_data  <= 8'd0;
            m_last  <= 1'b0;
        end else begin
            m_valid <= s_valid_reg;
            m_data  <= s_valid_reg ? clamped : m_data;
            m_last  <= s_last_reg;
        end
    end

endmodule