// This is the accel_top module.
`timescale 1ns / 1ps

module accel_top (
    input  wire        clk,
    input  wire        rst,

    // This section defines the interface for the sensor and analog-to-digital converter.
    input  wire        adc_valid,
    input  wire [15:0] adc_data,
    input  wire        adc_last,

    // SPI to MCU — feature transmission (FPGA = master)
    output wire        feat_spi_clk,
    output wire        feat_spi_mosi,
    output wire        feat_spi_cs_n,

    // SPI from MCU — config writes (FPGA = slave)
    input  wire        cfg_spi_clk,
    input  wire        cfg_spi_mosi,
    input  wire        cfg_spi_cs_n,

    // Status LEDs.
    output wire        led_busy,
    output wire        led_done
);

// These are the internal wire declarations connecting the sub-modules.

// These are the output signals from the configuration registers.
wire        cfg_start;
wire        cfg_mode_filter;   // We instantiate the configuration registers here.
wire [7:0]  cfg_scale;         // We instantiate the configuration registers here.

// This logic generates the write-enable signal for the scaling factor.
reg  [7:0]  scale_prev;
wire        scale_we;

// We instantiate the configuration registers here.
reg         started;           // Set by cfg_start pulse, cleared when tx_done.
wire        pipe_s_valid;

// This instantiates the top-level preprocessing pipeline.
wire        pp_m_valid;
wire [7:0]  pp_m_data;
wire        pp_m_last;

// Finally, we instantiate the SPI transmitter module.
wire        tx_busy;
wire        tx_done;

// This block implements the hold counter for the completion LED.
localparam  LED_HOLD = 24'd10_000_000;
reg  [23:0] led_done_ctr;

// Scale_we — 1-cycle pulse when cfg_scale changes.
always @(posedge clk) begin
    if (rst) scale_prev <= 8'd0;
    else     scale_prev <= cfg_scale;
end
assign scale_we = (cfg_scale != scale_prev) & ~rst;

// This flag manages the gating for the analog-to-digital converter.
// Set on cfg_start pulse; cleared when tx_done (spectrum fully sent)
always @(posedge clk) begin
    if (rst)          started <= 1'b0;
    else if (tx_done) started <= 1'b0;
    else if (cfg_start) started <= 1'b1;
end
assign pipe_s_valid = adc_valid & started;

// This block implements the hold counter for the completion LED.
always @(posedge clk) begin
    if (rst)          led_done_ctr <= 24'd0;
    else if (tx_done) led_done_ctr <= LED_HOLD;
    else if (led_done_ctr != 24'd0)
                      led_done_ctr <= led_done_ctr - 24'd1;
end

// Here we assign the internal status signals to the external LED pins.
assign led_busy = tx_busy;
assign led_done = (led_done_ctr != 24'd0);

// We instantiate the configuration registers here.
config_regs u_config_regs (
    .clk            (clk),
    .rst            (rst),
    .spi_clk        (cfg_spi_clk),
    .spi_mosi       (cfg_spi_mosi),
    .spi_cs_n       (cfg_spi_cs_n),
    .pipeline_busy  (tx_busy),
    .tx_done        (tx_done),
    .start          (cfg_start),
    .mode_filter    (cfg_mode_filter),
    .scale          (cfg_scale)
);

// This instantiates the top-level preprocessing pipeline.
preprocess_top u_preprocess_top (
    .clk            (clk),
    .rst            (rst),
    .s_valid        (pipe_s_valid),
    .s_data         (adc_data),
    .s_last         (adc_last),
    .mode_filter    (cfg_mode_filter),
    .scale_in       (cfg_scale),
    .scale_we       (scale_we),
    .m_valid        (pp_m_valid),
    .m_data         (pp_m_data),
    .m_last         (pp_m_last)
);

// Finally, we instantiate the SPI transmitter module.
spi_tx u_spi_tx (
    .clk            (clk),
    .rst            (rst),
    .s_valid        (pp_m_valid),
    .s_data         (pp_m_data),
    .s_last         (pp_m_last),
    .spi_clk        (feat_spi_clk),
    .spi_mosi       (feat_spi_mosi),
    .spi_cs_n       (feat_spi_cs_n),
    .tx_done        (tx_done),
    .busy           (tx_busy)
);

endmodule