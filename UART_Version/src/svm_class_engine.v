// =============================================================================
// File Name   : svm_class_engine.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module svm_class_engine #(
    parameter FEATURE_COUNT = 224,
    parameter CLASS_COUNT   = 5,
    parameter FEATURE_AW    = 8,
    parameter WEIGHT_AW     = 11,
    parameter ACC_W         = 48
)(
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      start,

    // Read data from external feature buffer and ROMs
    input  wire signed [7:0]         feature_data,
    input  wire signed [15:0]        weight_data,
    input  wire signed [31:0]        bias_data,

    // Address outputs back to external memories
    output reg  [FEATURE_AW-1:0]      feature_addr,
    output reg  [WEIGHT_AW-1:0]       weight_addr,
    output reg  [2:0]                 bias_addr,

    // Status
    output reg                        busy,
    output reg                        done,
    output reg                        scores_valid,

    // Final class scores
    output reg signed [ACC_W-1:0]     score0,
    output reg signed [ACC_W-1:0]     score1,
    output reg signed [ACC_W-1:0]     score2,
    output reg signed [ACC_W-1:0]     score3,
    output reg signed [ACC_W-1:0]     score4
);

    localparam S_IDLE       = 3'd0;
    localparam S_LOAD       = 3'd1;
    localparam S_ACCUM      = 3'd2;
    localparam S_LAST_ACCUM = 3'd3;
    localparam S_NEXT       = 3'd4;
    localparam S_FINISH     = 3'd5;

    reg [2:0] state;
    reg [2:0] class_idx;
    reg [7:0] feat_idx;

    reg signed [ACC_W-1:0] acc;
    
    // Pipeline register to cut the logic delay path from ROM -> Multiplier -> Accumulator
    reg signed [ACC_W-1:0] product_ext_reg;

    wire signed [23:0] product;
    svm_mac u_mac (
        .feature(feature_data),
        .weight (weight_data),
        .product(product)
    );

    wire signed [ACC_W-1:0] product_ext =
        {{(ACC_W-24){product[23]}}, product};

    wire signed [ACC_W-1:0] bias_ext =
        {{(ACC_W-32){bias_data[31]}}, bias_data};

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            class_idx       <= 3'd0;
            feat_idx        <= 8'd0;
            feature_addr    <= {FEATURE_AW{1'b0}};
            weight_addr     <= {WEIGHT_AW{1'b0}};
            bias_addr       <= 3'd0;
            busy            <= 1'b0;
            done            <= 1'b0;
            scores_valid    <= 1'b0;
            acc             <= {ACC_W{1'b0}};
            product_ext_reg <= {ACC_W{1'b0}};
            score0          <= {ACC_W{1'b0}};
            score1          <= {ACC_W{1'b0}};
            score2          <= {ACC_W{1'b0}};
            score3          <= {ACC_W{1'b0}};
            score4          <= {ACC_W{1'b0}};
        end else begin
            done         <= 1'b0;
            scores_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy         <= 1'b1;
                        class_idx    <= 3'd0;
                        feat_idx     <= 8'd0;
                        feature_addr <= {FEATURE_AW{1'b0}};
                        weight_addr  <= 11'd0;
                        bias_addr    <= 3'd0;
                        state        <= S_LOAD;
                    end
                end

                // S_LOAD handles the bias and captures the very first multiplier output
                S_LOAD: begin
                    acc             <= bias_ext;
                    product_ext_reg <= product_ext; // Captures product(0)
                    
                    // Increment for the next cycle
                    feature_addr    <= feature_addr + 8'd1;
                    weight_addr     <= weight_addr + 11'd1;
                    feat_idx        <= 8'd1;
                    
                    state <= S_ACCUM;
                end

                S_ACCUM: begin
                    // Add the delayed product to the accumulator
                    acc <= acc + product_ext_reg;
                    
                    // Capture the new product for the next cycle
                    product_ext_reg <= product_ext;

                    if (feat_idx == FEATURE_COUNT-1) begin
                        // Reached 223, go to S_LAST_ACCUM to add the final product(223)
                        state <= S_LAST_ACCUM;
                    end else begin
                        feat_idx     <= feat_idx + 8'd1;
                        feature_addr <= feature_addr + 8'd1;
                        weight_addr  <= weight_addr + 11'd1;
                    end
                end

                S_LAST_ACCUM: begin
                    // One final cycle to add the last pipelined product
                    case (class_idx)
                        3'd0: score0 <= acc + product_ext_reg;
                        3'd1: score1 <= acc + product_ext_reg;
                        3'd2: score2 <= acc + product_ext_reg;
                        3'd3: score3 <= acc + product_ext_reg;
                        3'd4: score4 <= acc + product_ext_reg;
                        default: ;
                    endcase
                    state <= S_NEXT;
                end

                S_NEXT: begin
                    if (class_idx == CLASS_COUNT-1) begin
                        state        <= S_FINISH;
                    end else begin
                        class_idx    <= class_idx + 3'd1;
                        feat_idx     <= 8'd0;
                        feature_addr <= {FEATURE_AW{1'b0}};
                        weight_addr  <= (class_idx + 3'd1) * 11'd224;
                        bias_addr    <= class_idx + 3'd1;
                        state        <= S_LOAD;
                    end
                end

                S_FINISH: begin
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    scores_valid <= 1'b1;
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule