// =============================================================================
// File Name   : filter_stage.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module filter_stage (
    input  wire        clk,
    input  wire        rst,
    input  wire        mode,

    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,

    output reg         m_valid,
    output reg  [15:0] m_data,
    output reg         m_last
);

    localparam signed [15:0] C0 = -16'd22;
    localparam signed [15:0] C1 =  16'd88;
    localparam signed [15:0] C2 =  16'd124;
    localparam signed [15:0] C3 =  16'd88;
    localparam signed [15:0] C4 = -16'd22;

    reg signed [15:0] r0, r1, r2, r3, r4;
    reg [6:0]  cnt;

    // Pipeline stage 1 registers
    reg signed [31:0] p_ma_sum;
    reg signed [39:0] p_sg0, p_sg1, p_sg2, p_sg3, p_sg4;
    reg capture_en_d;

    // Pipeline stage 2 (pipe registers)
    reg signed [15:0] ma_pipe, sg_pipe;
    
    wire capture_en;

    reg        s_valid_d;
    reg        s_valid_d2;
    reg        last_seen;

    reg [2:0]  flush_cnt;
    reg        flushing;
    reg        flushing_d;
    reg        flushing_d2;

    reg [1:0]  warmup;

    assign capture_en = (s_valid && !flushing && !last_seen) || (flushing && flush_cnt != 3'd0);

    always @(posedge clk) begin
        if (rst) begin
            r0<=0; r1<=0; r2<=0; r3<=0; r4<=0;
            cnt        <= 0;
            p_ma_sum   <= 0;
            p_sg0<=0; p_sg1<=0; p_sg2<=0; p_sg3<=0; p_sg4<=0;
            capture_en_d <= 0;
            ma_pipe    <= 0; sg_pipe    <= 0;
            s_valid_d  <= 0; s_valid_d2 <= 0;
            last_seen  <= 0;
            flushing   <= 0; flush_cnt  <= 0;
            flushing_d <= 0; flushing_d2 <= 0;
            warmup     <= 0;
        end else begin
            // ---------------------------------------------------------
            // PIPELINE STAGE 1: Multipliers and Sum
            // ---------------------------------------------------------
            p_ma_sum <= r0 + r1 + r2 + r3 + r4;
            p_sg0 <= C0 * r0;
            p_sg1 <= C1 * r1;
            p_sg2 <= C2 * r2;
            p_sg3 <= C3 * r3;
            p_sg4 <= C4 * r4;
            capture_en_d <= capture_en;

            // ---------------------------------------------------------
            // PIPELINE STAGE 2: Adders, Shift, and Pipe Registers
            // ---------------------------------------------------------
            if (capture_en_d) begin
                ma_pipe <= (p_ma_sum * 32'sd51) >>> 8;
                sg_pipe <= (p_sg0 + p_sg1 + p_sg2 + p_sg3 + p_sg4) >>> 8;
            end

            // ---------------------------------------------------------
            // DELAY REGISTERS FOR VALID/FLUSHING
            // ---------------------------------------------------------
            flushing_d  <= flushing;
            flushing_d2 <= flushing_d;
            s_valid_d2  <= s_valid_d;

            // ---------------------------------------------------------
            // INPUT SHIFT REGISTER AND CONTROL
            // ---------------------------------------------------------
            if (s_valid && !flushing && !last_seen) begin
                if (cnt == 7'd0) begin
                    r0<=s_data; r1<=s_data; r2<=s_data; r3<=s_data; r4<=s_data;
                end else begin
                    r0<=r1; r1<=r2; r2<=r3; r3<=r4; r4<=s_data;
                end
                cnt <= s_last ? 7'd0 : cnt + 7'd1;

                s_valid_d <= !s_last;

                if (s_last) begin
                    last_seen <= 1;
                    flushing  <= 1;
                    flush_cnt <= 3'd0;
                end
            end else begin
                s_valid_d <= 0;
            end

            if (flushing) begin
                if (flush_cnt != 3'd0) begin
                    r0<=r1; r1<=r2; r2<=r3; r3<=r4; // r4 frozen
                end
                flush_cnt <= flush_cnt + 3'd1;
                if (flush_cnt == 3'd3) begin
                    flushing  <= 0;
                    last_seen <= 0;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            m_valid <= 0; m_data <= 0; m_last <= 0;
            warmup  <= 0;
        end else begin
            m_valid <= 0;
            m_last  <= 0;

            if (s_valid_d2) begin
                if (warmup < 2'd3) begin
                    warmup <= warmup + 2'd1;
                end else begin
                    m_valid <= 1;
                    m_data  <= mode ? sg_pipe : ma_pipe;
                end
            end

            if (flushing_d2) begin
                m_valid <= 1;
                m_data  <= mode ? sg_pipe : ma_pipe;
                if (!flushing_d) begin
                    m_last <= 1;
                    warmup <= 0;
                end
            end
        end
    end

endmodule