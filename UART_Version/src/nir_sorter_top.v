// =============================================================================
// File Name   : nir_sorter_top.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
module nir_sorter_top(
    input  wire        clk,
    input  wire        rst,

    input  wire        mode_filter,
    input  wire [7:0]  scale_in,
    input  wire        scale_we,

    // Raw 224-sample spectrum input
    input  wire        s_valid,
    input  wire [15:0] s_data,
    input  wire        s_last,

    output wire [2:0]  class_id,
    output wire        class_valid,
    output wire        busy,
    output wire        result_valid
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
        .s_valid    (s_valid),
        .s_data     (s_data),
        .s_last     (s_last),
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

    controller_fsm u_ctrl (
        .clk            (clk),
        .rst            (rst),
        .frame_ready    (fb_frame_ready),
        .svm_busy       (svm_busy),
        .svm_done       (svm_done),
        .result_consumed(1'b0),
        .consume_frame  (consume_frame),
        .start_svm      (svm_start),
        .system_busy    (busy),
        .result_valid   (result_valid)
    );

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

endmodule
