// Zybo_top.v  -  NIR Preprocessing Accelerator, Zybo Z7-10 top level.
// This is the accel_top module.
// The ARM PS feeds raw ADC samples via a dual-port BRAM and reads.
// INT8 features back from a second BRAM.  No SPI needed - PS and PL.
// Share BRAMs through the AXI HP slave port (managed by Vivado block.
// Design), but this file contains ONLY the pure RTL wrapper that.
// Vivado wraps as a custom IP.  The block design connects the BRAMs.
// INTERFACE TO PS (via Vivado block design BRAMs):
// In_bram   [0:223]  16-bit  - PS writes 224 raw ADC samples.
// Out_bram  [0:223]   8-bit  - PS reads  224 INT8 features.
// Ctrl_reg  [1:0]     -  bit0=start (PS writes 1), bit1=done (PL writes 1)
// This instantiates the top-level preprocessing pipeline.
// Dark_correct → baseline_correct → filter_stage(SG-5) → snv_norm → quantiser.
// CONTROL FLOW:
// 1. ARM writes 224 samples into in_bram[0..223]
// 2. ARM writes ctrl_reg[0] = 1  (start pulse)
// 3. PL detects start, streams bram→pipeline over 224 cycles.
// 4. PL collects 224 INT8 outputs into out_bram[0..223]
// 5. PL asserts ctrl_reg[1] = 1  (done)
// 6. ARM polls done, reads out_bram.
// 7. ARM writes ctrl_reg[0] = 0  (clear, ready for next)
// LATENCY (100 MHz, window=5 filter):
// Pipeline latency  : ~1283 cycles  (~12.8 µs)
// BRAM read overhead:  224 cycles   (stream in)
// Total             : ~1507 cycles  (~15.1 µs per spectrum)
// Throughput        : ~66,000 spectra/sec.
// RESET: active-high synchronous rst (same as all submodules)
// CLOCK: 125 MHz from PS FCLK_CLK0 (Vivado block design)
// All timing constraints written for 125 MHz.

`timescale 1ns / 1ps

module zybo_top (
    // Clock + reset from PS (connected in block design)
    input  wire        clk,         // FCLK_CLK0 from ZYNQ7 PS (125 MHz)
    input  wire        rst,         // Active-high synchronous reset.

    // Connected to Port B of in_bram (Port A goes to PS AXI BRAM Controller)
    // FIX: widened to 32-bit to match blk_mem_gen Port B (32-bit wide BRAM)
    input  wire [31:0] bram_in_dout,   // Data read from in_bram (lower 16 bits used)
    // FIX: widened to 10-bit to match blk_mem_gen Port B address width.
    output reg  [ 9:0] bram_in_addr,   // Word address to read (0..223)
    output reg         bram_in_en,     // Read enable.

    // Connected to Port B of out_bram (Port A goes to PS AXI BRAM Controller)
    // FIX: widened to 32-bit, feature written into lowest byte.
    output reg  [31:0] bram_out_din,   // INT8 feature zero-padded to 32-bit.
    // FIX: widened to 10-bit to match blk_mem_gen Port B address width.
    output reg  [ 9:0] bram_out_addr,  // Word address to write (0..223)
    // FIX: 4-bit byte enable for 32-bit BRAM, only byte 0 enabled.
    output reg  [ 3:0] bram_out_we,    // Write enable (byte lanes)

    // Bit 0: start  (ARM writes 1 to begin; PL does not write this bit)
    // Bit 1: done   (PL writes 1 when output ready; ARM polls this)
    input  wire        ctrl_start,     // Ctrl_reg[0]  from AXI GPIO output.
    output reg         ctrl_done,      // Ctrl_reg[1]  to   AXI GPIO input.
    output reg bram_out_enb,
    // Mode_filter=1 → SG-5,  scale=110 - matches training script exactly.
    // We instantiate the configuration registers here.

    output wire [3:0]  led              // Led[0]=busy  led[1]=done  [3:2]=0.
);

// This instantiates the top-level preprocessing pipeline.
localparam [0:0]  P_MODE_FILTER = 1'b1;   // 1=SG-5 (matches training)
localparam [7:0]  P_SCALE       = 8'd110; // Quantiser scale (matches training)
localparam [7:0]  N_CHANNELS    = 8'd223; // Last channel index (0-based, 224 total)

// FSM states.
localparam S_IDLE     = 3'd0;  // Waiting for start pulse.
localparam S_READ     = 3'd1;  // Reading from in_bram, streaming to pipeline.
localparam S_WAIT     = 3'd2;  // Waiting for pipeline to finish (m_last)
localparam S_COLLECT  = 3'd3;  // Collecting output samples into out_bram.
localparam S_DONE     = 3'd4;  // Asserting done, waiting for ARM to clear start.

reg [2:0] state;

// This instantiates the top-level preprocessing pipeline.
reg         pp_s_valid;
reg  [15:0] pp_s_data;
reg         pp_s_last;

wire        pp_m_valid;
wire [7:0]  pp_m_data;
wire        pp_m_last;

// Rising-edge detector for pp_m_valid.
// Prevents FSM reacting to stale m_valid left high from previous spectrum.
reg         pp_m_valid_d;

// This instantiates the top-level preprocessing pipeline.
// Mode_filter and scale held constant (= training defaults)
// Scale_we never pulsed - scale stays at reset default (110)
preprocess_top u_preprocess (
    .clk         (clk),
    .rst         (rst),
    .mode_filter (P_MODE_FILTER),
    .scale_in    (P_SCALE),
    .scale_we    (1'b0),          // Scale fixed at P_SCALE; no runtime update.
    .s_valid     (pp_s_valid),
    .s_data      (pp_s_data),
    .s_last      (pp_s_last),
    .m_valid     (pp_m_valid),
    .m_data      (pp_m_data),
    .m_last      (pp_m_last)
);

// Counters.
reg [7:0] rd_cnt;   // Counts 0..223 during BRAM read.
reg [7:0] wr_cnt;   // Counts 0..223 during output collect.
reg       start_d;  // One-cycle delay to detect rising edge of ctrl_start.

// BRAM read pipeline delay.
// In_bram has 1-cycle read latency - we register rd_cnt and data valid.
// So that pp_s_data is valid one cycle after we assert bram_in_en.
reg        bram_rd_valid;   // Data valid one cycle after en.
reg        bram_rd_last;    // Last sample one cycle after en.

// Main FSM.
always @(posedge clk) begin
    if (rst) begin
        state        <= S_IDLE;
        rd_cnt       <= 8'd0;
        wr_cnt       <= 8'd0;
        start_d      <= 1'b0;
        ctrl_done    <= 1'b0;

        bram_in_addr <= 10'd0;
        bram_in_en   <= 1'b0;
        bram_rd_valid<= 1'b0;
        bram_rd_last <= 1'b0;

        // FIX: reset to 32-bit zero, 4-bit byte enable cleared.
        bram_out_din <= 32'd0;
        bram_out_addr<= 10'd0;
        bram_out_we  <= 4'b0000;
        bram_out_enb <=1'b0;

        pp_s_valid   <= 1'b0;
        pp_s_data    <= 16'd0;
        pp_s_last    <= 1'b0;
        pp_m_valid_d <= 1'b0;

    end else begin

        bram_in_en   <= 1'b0;
        bram_out_we  <= 4'b0000;
        bram_out_enb <=1'b0;
        pp_s_valid   <= 1'b0;
        pp_s_last    <= 1'b0;

        pp_m_valid_d <= pp_m_valid;

        // Whatever en+addr we issued last cycle, data arrives this cycle.
        bram_rd_valid <= bram_in_en;
        bram_rd_last  <= (bram_in_addr == {N_CHANNELS,2'b00}) & bram_in_en;

        if (bram_rd_valid) begin
            pp_s_valid <= 1'b1;
            // FIX: ARM writes u16 sample into lower 16 bits of 32-bit word.
            pp_s_data  <= bram_in_dout[15:0];
            pp_s_last  <= bram_rd_last;
        end

        start_d <= ctrl_start;

        case (state)

            S_IDLE: begin
                ctrl_done <= 1'b0;
                rd_cnt    <= 8'd0;
                wr_cnt    <= 8'd0;

                // Start on rising edge of ctrl_start.
                if (ctrl_start & ~start_d) begin
                    state        <= S_READ;
                    // FIX: zero-extend 8-bit counter to 10-bit address.
                    bram_in_addr <= 10'd0;
                    bram_in_en   <= 1'b1;   // Issue first read.
                    rd_cnt       <= 8'd1;   // Next address.
                end
            end

            // S_READ: issue BRAM reads for addresses 0..223 on consecutive.
            // Cycles.  Data arrives one cycle later (bram_rd_valid).
            // After issuing the last address, move to S_WAIT.
            S_READ: begin
                if (rd_cnt <= N_CHANNELS) begin
                    // FIX: zero-extend rd_cnt to 10-bit address.
                    bram_in_addr <= {rd_cnt,2'b00};
                    bram_in_en   <= 1'b1;
                    rd_cnt       <= rd_cnt + 8'd1;
                end else begin
                    // All addresses issued; last data still in flight.
                    state <= S_WAIT;
                end
            end

            // S_WAIT: wait for a RISING EDGE on pp_m_valid so we never react.
            // To a stale m_valid left high from the previous spectrum.
            // FIX: also handle pp_m_last arriving on the same cycle.
            // As the first rising edge (burst of 1 or short pipeline).
            // If m_last is coincident with the first rising edge,.
            // Go straight to S_DONE after writing the single sample.
            S_WAIT: begin
                if (pp_m_valid && !pp_m_valid_d) begin
                    // Fresh rising edge — first real output sample arrived.
                    bram_out_din  <= {24'd0, pp_m_data};
                    bram_out_addr <= 10'd0;
                    bram_out_we   <= 4'b0001;
                    bram_out_enb  <= 1'b1;
                    wr_cnt        <= 8'd1;
                    // FIX: if m_last coincides with first valid, skip S_COLLECT.
                    if (pp_m_last)
                        state <= S_DONE;
                    else
                        state <= S_COLLECT;
                end
            end

            // S_COLLECT: write each INT8 output into out_bram as it arrives.
            // Transition to S_DONE on m_last.
            S_COLLECT: begin
                if (pp_m_valid) begin
                    // FIX: zero-pad 8-bit feature into 32-bit word (byte 0)
                    bram_out_din  <= {24'd0, pp_m_data};
                    // FIX: zero-extend wr_cnt to 10-bit address.
                    bram_out_addr <= {wr_cnt,2'b00};
                    // FIX: 4-bit byte enable - only byte 0.
                    bram_out_we   <= 4'b0001;
                    bram_out_enb <=1'b1;
                    wr_cnt        <= wr_cnt + 8'd1;
                end

                if (pp_m_last) begin
                    state <= S_DONE;
                end
            end

            // S_DONE: assert ctrl_done, wait for ARM to deassert ctrl_start.
            // (ARM clears start after reading results)
           S_DONE: begin
            ctrl_done <= 1'b1;          // Assert done — holds until next cycle minimum.
            if (ctrl_done & ~ctrl_start) begin  // Only clear AFTER ctrl_done has been high.
                state     <= S_IDLE;
                ctrl_done <= 1'b0;
            end
        end

            default: state <= S_IDLE;

        endcase
    end
end

// Here we assign the internal status signals to the external LED pins.
// Led[0] = busy  (pipeline running - any state except IDLE/DONE)
// Led[1] = done  (result ready, held until ARM clears start)
// Led[2] = heartbeat placeholder (tie 0)
// Led[3] = tie 0.
assign led[0] = (state != S_IDLE) & (state != S_DONE);
assign led[1] = ctrl_done;
assign led[2] = 1'b0;
assign led[3] = 1'b0;

endmodule