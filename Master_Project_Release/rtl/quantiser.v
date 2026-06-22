// Quantiser.v  — updated for SPECIM FX17e / PCA pipeline.
// CHANGE: default scale 42 -> 110.
// Scale=42 was calibrated for ±3.0 SNV -> ±127 INT8.
// Scale=110 matches pca_scale from training script:
// Pca_scale = floor(100.0 / pca_95th_percentile) = 110.
// This maps SNV output correctly as input to pca_project stage.
// Everything else identical to previous version.
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

    // Scale register — default 110 (was 42)
    reg [7:0] scale;

    always @(posedge clk) begin
        if (rst)           scale <= 8'd110;   // Was 8'd42.
        else if (scale_we) scale <= scale_in;
    end

    // Datapath: signed multiply + right-shift + clamp.
    wire signed [23:0] product = $signed(s_data) * $signed({1'b0, scale});
    wire signed [23:0] shifted = product >>> 8;

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
            m_valid <= s_valid;
            m_data  <= s_valid ? clamped : m_data;
            m_last  <= s_last;
        end
    end

endmodule