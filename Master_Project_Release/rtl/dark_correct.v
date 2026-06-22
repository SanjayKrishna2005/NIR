// Dark_correct.v.
// Stage 0 of the NIR preprocessing pipeline.
// Subtracts per-channel dark current from raw ADC input.
// OPERATION (per sample, streaming):
// Diff  = {1'b0, s_data} - {1'b0, dark_rom[ch]}   17-bit, detects underflow.
// M_data = diff[16] ? 16'd0 : diff[15:0]            clamp to 0 if negative.
// ROM: dark_current.hex  224 × 16-bit  (0x00E3 = 227 counts)
// LATENCY  : 1 clock cycle (registered output)
// INTERFACE: s_valid/s_data/s_last → m_valid/m_data/m_last.
// Input  : 16-bit unsigned raw ADC.
// Output : 16-bit unsigned, dark-corrected, clamped >= 0.

module dark_correct (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire        s_last,
    input  wire [15:0] s_data,
    output reg         m_valid,
    output reg         m_last,
    output reg  [15:0] m_data
);

    // ROM: 224 entries x 16-bit.
    reg [15:0] dark_rom [0:223];
    initial $readmemh("dark_current.hex", dark_rom);

    // Channel counter [7:0] counts 0..223.
    reg [7:0] ch;

    // 17-bit subtraction — bit[16]=1 means underflow.
    wire [16:0] diff = {1'b0, s_data} - {1'b0, dark_rom[ch]};

    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0;
            m_last  <= 1'b0;
            m_data  <= 16'd0;
            ch      <= 8'd0;
        end else begin
            m_valid <= s_valid;
            m_last  <= s_last;

            if (s_valid) begin
                // Clamp: underflow -> 0, else pass diff.
                m_data <= diff[16] ? 16'd0 : diff[15:0];
                // Reset counter on last sample.
                ch <= s_last ? 8'd0 : ch + 8'd1;
            end
        end
    end

endmodule