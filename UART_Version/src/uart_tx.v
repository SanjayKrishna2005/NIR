// =============================================================================
// File Name   : uart_tx.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module uart_tx #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire       i_Clock,
    input  wire       i_Rst_L,
    input  wire       i_Tx_DV,
    input  wire [7:0] i_Tx_Byte,
    output reg        o_Tx_Active,
    output reg        o_Tx_Serial,
    output reg        o_Tx_Done
);

    localparam s_IDLE       = 3'd0;
    localparam s_TX_START   = 3'd1;
    localparam s_TX_DATA    = 3'd2;
    localparam s_TX_STOP    = 3'd3;
    localparam s_CLEANUP    = 3'd4;

    reg [2:0] state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  tx_byte;

    always @(posedge i_Clock) begin
        if (!i_Rst_L) begin
            state       <= s_IDLE;
            clk_count   <= 16'd0;
            bit_index   <= 3'd0;
            tx_byte     <= 8'd0;
            o_Tx_Active <= 1'b0;
            o_Tx_Serial <= 1'b1;
            o_Tx_Done   <= 1'b0;
        end else begin
            o_Tx_Done <= 1'b0;

            case (state)
                s_IDLE: begin
                    o_Tx_Active <= 1'b0;
                    o_Tx_Serial <= 1'b1;
                    clk_count   <= 16'd0;
                    bit_index   <= 3'd0;

                    if (i_Tx_DV) begin
                        tx_byte     <= i_Tx_Byte;
                        o_Tx_Active <= 1'b1;
                        state       <= s_TX_START;
                    end
                end

                s_TX_START: begin
                    o_Tx_Serial <= 1'b0;
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        clk_count <= 16'd0;
                        state     <= s_TX_DATA;
                    end
                end

                s_TX_DATA: begin
                    o_Tx_Serial <= tx_byte[bit_index];
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        clk_count <= 16'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state     <= s_TX_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end
                end

                s_TX_STOP: begin
                    o_Tx_Serial <= 1'b1;
                    if (clk_count < CLKS_PER_BIT-1) begin
                        clk_count <= clk_count + 16'd1;
                    end else begin
                        o_Tx_Done   <= 1'b1;
                        o_Tx_Active <= 1'b0;
                        clk_count   <= 16'd0;
                        state       <= s_CLEANUP;
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
