// =============================================================================
// File Name   : nir_sorter_uart_top.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module nir_sorter_uart_top #(
    parameter CLKS_PER_BIT = 868
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        uart_rx_in,
    output wire        uart_tx_out,

    input  wire        mode_filter,
    input  wire [7:0]  scale_in,
    input  wire        scale_we
);

    wire rst = ~rst_n;

    // UART RX
    wire       rx_dv;
    wire [7:0] rx_byte;
    wire       rx_fe;

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_rx (
        .i_Clock        (clk),
        .i_Rst_L        (rst_n),
        .i_Rx_Serial    (uart_rx_in),
        .o_Rx_DV        (rx_dv),
        .o_Rx_Byte      (rx_byte),
        .o_Framing_Error(rx_fe)
    );

    // Simple protocol:
    //   0xA5 starts a frame, then 448 bytes follow (224 samples × 2 bytes)
    wire load_start;
    assign load_start = rx_dv && (rx_byte == 8'hA5);

    wire        sample_valid;
    wire [15:0] sample_data;
    wire        sample_last;
    wire [7:0]  sample_index;
    wire        spectrum_ready;

    spectrum_loader u_loader (
        .clk         (clk),
        .rst         (rst),
        .load_start  (load_start),
        .byte_valid  (rx_dv && (rx_byte != 8'hA5)),
        .byte_in     (rx_byte),
        .sample_valid(sample_valid),
        .sample_data (sample_data),
        .sample_last (sample_last),
        .sample_index(sample_index),
        .frame_ready (spectrum_ready)
    );

    wire pre_m_valid;
    wire [7:0] pre_m_data;
    wire pre_m_last;

    preprocess_top u_pre (
        .clk        (clk),
        .rst        (rst),
        .mode_filter(mode_filter),
        .scale_in   (scale_in),
        .scale_we   (scale_we),
        .s_valid    (sample_valid),
        .s_data     (sample_data),
        .s_last     (sample_last),
        .m_valid    (pre_m_valid),
        .m_data     (pre_m_data),
        .m_last     (pre_m_last)
    );

    wire fb_frame_ready;
    wire fb_frame_full;
    wire [7:0] fb_wr_ptr;
    wire consume_frame;

    wire signed [7:0] feat_rdata;
    wire [7:0] feat_raddr;

    feature_buffer u_fb (
        .clk        (clk),
        .rst        (rst),
        .s_valid    (pre_m_valid),
        .s_data     (pre_m_data),
        .s_last     (pre_m_last),
        .consume    (consume_frame),
        .r_addr     (feat_raddr),
        .r_data     (feat_rdata),
        .frame_ready(fb_frame_ready),
        .frame_full (fb_frame_full),
        .wr_ptr     (fb_wr_ptr)
    );

    wire [10:0] weight_addr;
    wire [2:0]  bias_addr;
    wire signed [15:0] weight_data;
    wire signed [31:0] bias_data;

    svm_weight_rom u_wrom (
        .rd_addr(weight_addr),
        .rd_data(weight_data)
    );

    svm_bias_rom u_brom (
        .rd_addr(bias_addr),
        .rd_data(bias_data)
    );

    wire svm_start;
    wire svm_done;
    wire svm_busy;
    wire svm_scores_valid;
    wire signed [47:0] score0, score1, score2, score3, score4;

    svm_class_engine u_svm (
        .clk         (clk),
        .rst         (rst),
        .start       (svm_start),
        .feature_data(feat_rdata),
        .weight_data (weight_data),
        .bias_data   (bias_data),
        .feature_addr(feat_raddr),
        .weight_addr (weight_addr),
        .bias_addr   (bias_addr),
        .busy        (svm_busy),
        .done        (svm_done),
        .scores_valid(svm_scores_valid),
        .score0      (score0),
        .score1      (score1),
        .score2      (score2),
        .score3      (score3),
        .score4      (score4)
    );

    wire class_valid;
    wire [2:0] class_id;
    wire signed [47:0] max_score_unused;

    argmax u_argmax (
        .clk         (clk),
        .rst         (rst),
        .scores_valid(svm_scores_valid),
        .score0      (score0),
        .score1      (score1),
        .score2      (score2),
        .score3      (score3),
        .score4      (score4),
        .class_id    (class_id),
        .class_valid (class_valid),
        .max_score   (max_score_unused)
    );

    // Simple control: if a feature frame is ready, kick off classification.
    controller_fsm u_ctrl (
        .clk            (clk),
        .rst            (rst),
        .frame_ready    (fb_frame_ready),
        .svm_busy       (svm_busy),
        .svm_done       (svm_done),
        .result_consumed(1'b0),
        .consume_frame  (consume_frame),
        .start_svm      (svm_start),
        .system_busy    (),
        .result_valid   ()
    );

    // UART TX: send ASCII digit '1'..'5' and newline when classification done.
    reg        tx_dv;
    reg [7:0]  tx_byte;
    wire       tx_active;
    wire       tx_done;

    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) u_tx (
        .i_Clock    (clk),
        .i_Rst_L    (rst_n),
        .i_Tx_DV    (tx_dv),
        .i_Tx_Byte  (tx_byte),
        .o_Tx_Active(tx_active),
        .o_Tx_Serial(uart_tx_out),
        .o_Tx_Done  (tx_done)
    );

    localparam T_IDLE  = 2'd0;
    localparam T_SEND1 = 2'd1;
    localparam T_SEND2 = 2'd2;

    reg [1:0] tx_state;

    always @(posedge clk) begin
        if (rst) begin
            tx_state <= T_IDLE;
            tx_dv    <= 1'b0;
            tx_byte  <= 8'h00;
        end else begin
            tx_dv <= 1'b0;

            case (tx_state)
                T_IDLE: begin
                    if (class_valid) begin
                        tx_byte  <= 8'h30 + class_id; // ASCII '1'..'5'
                        tx_dv    <= 1'b1;
                        tx_state <= T_SEND1;
                    end
                end

                T_SEND1: begin
                    if (tx_done) begin
                        tx_byte  <= 8'h0A; // newline
                        tx_dv    <= 1'b1;
                        tx_state <= T_SEND2;
                    end
                end

                T_SEND2: begin
                    if (tx_done) begin
                        tx_state <= T_IDLE;
                    end
                end

                default: tx_state <= T_IDLE;
            endcase
        end
    end

endmodule
