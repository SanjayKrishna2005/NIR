// =============================================================================
// File Name   : uart_rx.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module uart_rx #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire       i_Clock,
    input  wire       i_Rst_L,
    input  wire       i_Rx_Serial,
    output reg        o_Rx_DV,
    output reg [7:0]  o_Rx_Byte,
    output reg        o_Framing_Error
);

    localparam s_IDLE         = 3'd0;
    localparam s_RX_START_BIT  = 3'd1;
    localparam s_RX_DATA_BITS  = 3'd2;
    localparam s_RX_STOP_BIT   = 3'd3;
    localparam s_CLEANUP       = 3'd4;

    reg [2:0] state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]   rx_shift;

    always @(posedge i_Clock) begin
        if (!i_Rst_L) begin
            state           <= s_IDLE;
            clk_count       <= 16'd0;
            bit_index       <= 3'd0;
            rx_shift        <= 8'd0;
            o_Rx_DV         <= 1'b0;
            o_Rx_Byte       <= 8'd0;
            o_Framing_Error <= 1'b0;
        end else begin
            o_Rx_DV <= 1'b0;

            case (state)
                s_IDLE: begin
                    o_Framing_Error <= 1'b0;
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;

                    if (i_Rx_Serial == 1'b0)
                        state <= s_RX_START_BIT;
                end

                s_RX_START_BIT: begin
                    if (clk_count == (CLKS_PER_BIT-1)/2) begin
                        if (i_Rx_Serial == 1'b0) begin
                            clk_count <= 16'd0;
                            state     <= s_RX_DATA_BITS;
                        end else begin
                            state <= s_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                s_RX_DATA_BITS: begin
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        clk_count <= 16'd0;
                        rx_shift[bit_index] <= i_Rx_Serial;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= s_RX_STOP_BIT;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end
                end

                s_RX_STOP_BIT: begin
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        o_Rx_Byte <= rx_shift;
                        o_Rx_DV   <= 1'b1;
                        o_Framing_Error <= (i_Rx_Serial != 1'b1);
                        clk_count <= 16'd0;
                        state     <= s_CLEANUP;
                    end
                end

                s_CLEANUP: begin
                    state <= s_IDLE;
                end

                default: state <= s_IDLE;
            endcase
        end
    end

endmodule
