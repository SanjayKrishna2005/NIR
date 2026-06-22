// =============================================================================
// File Name   : baseline_correct.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================

module baseline_correct (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,
    output reg         m_valid,
    output reg  [15:0] m_data,
    output reg         m_last
);

    localparam ACCUMULATE = 1'b0;
    localparam SUBTRACT   = 1'b1;

    reg state;

    reg signed [15:0] buffer [0:223];   // was [0:127]
    reg signed [23:0] acc;
    reg signed [15:0] mean;
    reg        [7:0]  count;            // was [6:0]

    always @(posedge clk) begin
        if (rst) begin
            state   <= ACCUMULATE;
            count   <= 8'd0;
            acc     <= 24'd0;
            mean    <= 16'd0;
            m_valid <= 1'b0;
            m_last  <= 1'b0;
        end else begin
            m_last  <= 1'b0;
            m_valid <= 1'b0;

            case (state)

                ACCUMULATE: begin
                    if (s_valid) begin
                        buffer[count] <= $signed(s_data);
                        if (count == 8'd223) begin          // was 7'd127
                            mean  <= (acc + $signed(s_data)) >>> 8; // was >>7
                            acc   <= 24'd0;
                            count <= 8'd0;
                            state <= SUBTRACT;
                        end else begin
                            acc   <= acc + $signed(s_data);
                            count <= count + 8'd1;
                        end
                    end
                end

                SUBTRACT: begin
                    m_data  <= buffer[count] - mean;
                    m_valid <= 1'b1;
                    if (count == 8'd223) begin              // was 7'd127
                        m_last <= 1'b1;
                        state  <= ACCUMULATE;
                        count  <= 8'd0;
                    end else begin
                        count <= count + 8'd1;
                    end
                end

            endcase
        end
    end

endmodule