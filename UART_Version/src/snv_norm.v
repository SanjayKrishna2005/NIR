// =============================================================================
// File Name   : snv_norm.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module snv_norm (
    input  wire        clk,
    input  wire        rst,
    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,
    output reg         m_valid,
    output reg  [15:0] m_data,
    output reg         m_last
);

    // Sample buffer: 224 x 16-bit signed
    reg signed [15:0] buf_mem [0:223];      // was [0:127]

    // FSM states
    localparam S_PASS1    = 3'd0;
    localparam S_PASS2    = 3'd1;
    localparam S_SQRT     = 3'd2;
    localparam S_SQRT_CMP = 3'd3;
    localparam S_RECIP    = 3'd4;
    localparam S_PASS3    = 3'd5;

    reg [2:0] state;

    // Counter: [7:0] counts 0..223
    reg [7:0] cnt;

    // PASS1
    reg signed [23:0] sum;
    reg signed [15:0] mean;

    // PASS2 - 2-stage pipeline
    reg signed [15:0] centred_r;
    reg        [31:0] csq_r;
    reg        [39:0] sum_sq;

    // SQRT - restoring, 17-bit root of 33-bit variance
    reg [32:0] var_reg;
    reg [16:0] sq_root;
    reg [4:0]  sq_bit;
    
    // SQRT Pipeline Registers
    reg [16:0] trial_root_reg;
    reg [33:0] trial_sq_reg;

    // RECIP - 2^15 / std_dev
    reg [15:0] std_dev;
    reg [16:0] div_rem;
    reg [14:0] div_quot;
    reg [4:0]  div_bit;
    reg [14:0] recip;

    // Temp variables (blocking - Vivado compatible)
    reg [16:0] trial_root;
    reg [33:0] trial_sq;
    reg [16:0] partial;
    reg [15:0] divisor;
    reg        d_bit;

    // PASS3 combinational path & pipeline registers
    reg signed [15:0] centred_p3_reg;
    reg               p3_valid;
    reg               p3_last;

    wire signed [31:0] product    = centred_p3_reg * $signed({1'b0, recip});
    wire signed [15:0] snv_out    = product[26:11];

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_PASS1;
            cnt            <= 8'd0;
            sum            <= 24'd0;
            mean           <= 16'd0;
            centred_r      <= 16'd0;
            csq_r          <= 32'd0;
            sum_sq         <= 40'd0;
            var_reg        <= 33'd0;
            sq_root        <= 17'd0;
            sq_bit         <= 5'd16;
            trial_root_reg <= 17'd0;
            trial_sq_reg   <= 34'd0;
            std_dev        <= 16'd0;
            div_rem        <= 17'd0;
            div_quot       <= 15'd0;
            div_bit        <= 5'd15;
            recip          <= 15'd0;
            trial_root     <= 17'd0;
            trial_sq       <= 34'd0;
            partial        <= 17'd0;
            divisor        <= 16'd0;
            d_bit          <= 1'b0;
            m_valid        <= 1'b0;
            m_data         <= 16'd0;
            m_last         <= 1'b0;
            
            p3_valid       <= 1'b0;
            p3_last        <= 1'b0;
            centred_p3_reg <= 16'd0;

        end else begin
            // -------------------------------------------------------------
            // Pipeline assignment for S_PASS3
            // -------------------------------------------------------------
            p3_valid       <= (state == S_PASS3);
            p3_last        <= (state == S_PASS3 && cnt == 8'd223);
            centred_p3_reg <= $signed(buf_mem[cnt]) - mean;

            m_valid        <= p3_valid;
            m_last         <= p3_last;
            if (p3_valid) begin
                m_data <= snv_out;
            end else begin
                // Keep m_data stable or 0, usually keeping it is fine.
                // Just clear to 0 if not valid to keep logic clean.
                // Or leave it alone. Leaving alone is usually fine.
            end

            case (state)

                // -------------------------------------------------------------
                // PASS1: buffer 224 samples, accumulate sum
                // -------------------------------------------------------------
                S_PASS1: begin
                    if (s_valid) begin
                        buf_mem[cnt] <= $signed(s_data);

                        if (cnt == 8'd223 || s_last) begin
                            mean  <= (sum + $signed(s_data)) >>> 8;
                            sum   <= 24'd0;
                            cnt   <= 8'd0;
                            state <= S_PASS2;
                        end else begin
                            sum <= sum + $signed(s_data);
                            cnt <= cnt + 8'd1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // PASS2: accumulate sum of (x - mean)^2
                // -------------------------------------------------------------
                S_PASS2: begin
                    centred_r <= buf_mem[cnt] - mean;
                    csq_r     <= centred_r * centred_r;

                    if (cnt > 8'd0)
                        sum_sq <= sum_sq + {8'd0, csq_r};

                    if (cnt == 8'd223) begin
                        cnt   <= 8'd0;
                        state <= S_SQRT;
                    end else begin
                        cnt <= cnt + 8'd1;
                    end
                end

                // -------------------------------------------------------------
                // SQRT: restoring square root of variance (Cycle 1: Multiply)
                // -------------------------------------------------------------
                S_SQRT: begin
                    if (cnt == 8'd0) begin
                        var_reg <= (sum_sq + {8'd0, csq_r}) >> 8;
                        sum_sq  <= 40'd0;
                        sq_root <= 17'd0;
                        sq_bit  <= 5'd16;
                        cnt     <= 8'd1;
                    end else begin
                        trial_root = sq_root | (17'd1 << sq_bit);
                        trial_sq   = trial_root * trial_root;
                        
                        trial_root_reg <= trial_root;
                        trial_sq_reg   <= trial_sq;
                        state          <= S_SQRT_CMP;
                    end
                end

                // -------------------------------------------------------------
                // SQRT_CMP: restoring square root (Cycle 2: Compare & MUX)
                // -------------------------------------------------------------
                S_SQRT_CMP: begin
                    if (trial_sq_reg <= {1'b0, var_reg}) begin
                        sq_root <= trial_root_reg;
                    end

                    if (sq_bit == 5'd0) begin
                        std_dev  <= (trial_sq_reg <= {1'b0, var_reg}) ? trial_root_reg[15:0] : sq_root[15:0];
                        div_rem  <= 17'd0;
                        div_quot <= 15'd0;
                        div_bit  <= 5'd15;
                        cnt      <= 8'd0;
                        state    <= S_RECIP;
                    end else begin
                        sq_bit <= sq_bit - 5'd1;
                        state  <= S_SQRT;
                    end
                end

                // -------------------------------------------------------------
                // RECIP: compute 32768 / std_dev (15-bit restoring divider)
                // -------------------------------------------------------------
                S_RECIP: begin
                    divisor = (std_dev == 16'd0) ? 16'd1 : std_dev;
                    d_bit   = (div_bit == 5'd15) ? 1'b1 : 1'b0;
                    partial = {div_rem[15:0], d_bit};

                    if (partial >= {1'b0, divisor}) begin
                        div_quot <= (div_quot << 1) | 15'd1;
                        div_rem  <= partial - {1'b0, divisor};
                    end else begin
                        div_quot <= div_quot << 1;
                        div_rem  <= partial;
                    end

                    if (div_bit == 5'd0) begin
                        recip   <= (std_dev == 16'd0) ? 15'h7FFF : div_quot;
                        cnt     <= 8'd0;
                        state   <= S_PASS3;
                    end else begin
                        div_bit <= div_bit - 5'd1;
                    end
                end

                // -------------------------------------------------------------
                // PASS3: stream normalised output for all 224 samples
                // -------------------------------------------------------------
                S_PASS3: begin
                    if (cnt == 8'd223) begin
                        cnt    <= 8'd0;
                        state  <= S_PASS1;
                    end else begin
                        cnt <= cnt + 8'd1;
                    end
                end

                default: state <= S_PASS1;

            endcase
        end
    end

endmodule