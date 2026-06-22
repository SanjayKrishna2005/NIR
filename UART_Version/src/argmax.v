// =============================================================================
// File Name   : argmax.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module argmax #(
    parameter ACC_W = 48
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     scores_valid,

    input  wire signed [ACC_W-1:0]  score0,
    input  wire signed [ACC_W-1:0]  score1,
    input  wire signed [ACC_W-1:0]  score2,
    input  wire signed [ACC_W-1:0]  score3,
    input  wire signed [ACC_W-1:0]  score4,

    output reg  [2:0]               class_id,
    output reg                      class_valid,
    output reg signed [ACC_W-1:0]   max_score
);

    reg [2:0]               winner;
    reg signed [ACC_W-1:0]  max_score_comb;

    always @* begin
        winner         = 3'd1;
        max_score_comb = score0;

        if (score1 > max_score_comb) begin winner = 3'd2; max_score_comb = score1; end
        if (score2 > max_score_comb) begin winner = 3'd3; max_score_comb = score2; end
        if (score3 > max_score_comb) begin winner = 3'd4; max_score_comb = score3; end
        if (score4 > max_score_comb) begin winner = 3'd5; max_score_comb = score4; end
    end

    // Pipeline registers to allow Vivado's Register Retiming
    reg [2:0]               class_id_r1;
    reg [2:0]               class_id_r2;
    reg                     class_valid_r1;
    reg                     class_valid_r2;
    reg signed [ACC_W-1:0]  max_score_r1;
    reg signed [ACC_W-1:0]  max_score_r2;

    always @(posedge clk) begin
        if (rst) begin
            class_id_r1    <= 3'd0;
            class_id_r2    <= 3'd0;
            class_id       <= 3'd0;
            class_valid_r1 <= 1'b0;
            class_valid_r2 <= 1'b0;
            class_valid    <= 1'b0;
            max_score_r1   <= {ACC_W{1'b0}};
            max_score_r2   <= {ACC_W{1'b0}};
            max_score      <= {ACC_W{1'b0}};
        end else begin
            // Stage 1
            class_valid_r1 <= scores_valid;
            if (scores_valid) begin
                class_id_r1  <= winner;
                max_score_r1 <= max_score_comb;
            end

            // Stage 2
            class_valid_r2 <= class_valid_r1;
            class_id_r2    <= class_id_r1;
            max_score_r2   <= max_score_r1;

            // Stage 3 (Output)
            class_valid    <= class_valid_r2;
            class_id       <= class_id_r2;
            max_score      <= max_score_r2;
        end
    end

endmodule
