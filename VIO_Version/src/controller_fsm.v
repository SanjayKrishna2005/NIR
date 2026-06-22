// =============================================================================
// File Name   : controller_fsm.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module controller_fsm(
    input  wire clk,
    input  wire rst,

    input  wire frame_ready,
    input  wire svm_busy,
    input  wire svm_done,
    input  wire result_consumed, // reserved for future use

    output reg  consume_frame,
    output reg  start_svm,
    output reg  system_busy,
    output reg  result_valid
);

    localparam C_IDLE = 2'd0;
    localparam C_WAIT = 2'd1;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state         <= C_IDLE;
            consume_frame <= 1'b0;
            start_svm     <= 1'b0;
            system_busy   <= 1'b0;
            result_valid  <= 1'b0;
        end else begin
            consume_frame <= 1'b0;
            start_svm     <= 1'b0;
            result_valid  <= 1'b0;

            case (state)
                C_IDLE: begin
                    system_busy <= 1'b0;
                    if (frame_ready && !svm_busy) begin
                        consume_frame <= 1'b1;
                        start_svm     <= 1'b1;
                        system_busy   <= 1'b1;
                        state         <= C_WAIT;
                    end
                end

                C_WAIT: begin
                    system_busy <= 1'b1;
                    if (svm_done) begin
                        result_valid <= 1'b1;
                        state        <= C_IDLE;
                    end
                end

                default: state <= C_IDLE;
            endcase
        end
    end

endmodule
