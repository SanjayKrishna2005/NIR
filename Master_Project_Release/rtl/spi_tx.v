// Finally, we instantiate the SPI transmitter module.
// Project : FPGA NIR Spectroscopy Preprocessing Accelerator.
// Purpose : Collect 224 INT8 samples from the preprocessing pipeline into a.
// Buffer, then serialise all 224 bytes to an MCU over SPI Mode 0.
// (CPOL=0, CPHA=0), MSB first, FPGA as master.
// SPI timing (Mode 0):
// Spi_cs_n goes low  → idle clock low.
// Data driven on MOSI on falling edge of spi_clk (or before first rising)
// MCU latches MOSI   on rising  edge of spi_clk.
// Spi_cs_n goes high after last falling edge of last bit.
// Clock relationship:
// SPI half-period = CLK_DIV system cycles.
// SPI full period = 2*CLK_DIV system cycles.
// SPI frequency   = sys_clk / (2*CLK_DIV)

module spi_tx #(
    parameter integer N       = 224,   // Samples per spectrum.
    parameter integer CLK_DIV = 4      // SPI freq = sys_clk / (2*CLK_DIV)
) (
    input  wire        clk,        // System clock.
    input  wire        rst,        // Synchronous active-high reset.

    input  wire        s_valid,    // One sample valid per cycle.
    input  wire [7:0]  s_data,     // INT8 sample from quantiser.
    input  wire        s_last,     // High on the 224th (final) sample.

    output reg         spi_clk,    // SPI clock to MCU.
    output reg         spi_mosi,   // SPI data  to MCU (MSB first)
    output reg         spi_cs_n,   // SPI chip select (active-low)

    output reg         tx_done,    // Pulses high for exactly 1 cycle when done.
    output reg         busy        // High throughout COLLECT + TRANSMIT.
);

// Local parameters.
localparam integer ADDR_W  = $clog2(N);          // 8 bits for N=224.
localparam integer CNT_W   = $clog2(CLK_DIV);    // Counter width.

// FSM state encoding.
localparam [1:0]
    S_IDLE     = 2'd0,
    S_COLLECT  = 2'd1,
    S_TRANSMIT = 2'd2,
    S_DONE     = 2'd3;

// Sample buffer  (224 × 8-bit)
reg [7:0] buf_mem [0:N-1];

// Registers.
reg [1:0]           state;

// COLLECT.
reg [ADDR_W-1:0]    sample_cnt;   // 0..223, index of next sample to store.

// TRANSMIT.
reg [ADDR_W-1:0]    byte_cnt;     // 0..223, current byte being shifted.
reg [2:0]           bit_cnt;      // 7..0,   current bit within byte.
reg [CNT_W-1:0]     clk_cnt;      // Counts 0..CLK_DIV-1 per half-period.
reg                 clk_phase;    // 0 = about to produce rising edge.
                                  // 1 = about to produce falling edge.
reg                 last_byte;    // Combinational: byte_cnt == N-1.
reg                 last_bit;     // Combinational: bit_cnt  == 0.

// Combinational helpers.
always @(*) begin
    last_byte = (byte_cnt == (N-1));
    last_bit  = (bit_cnt  == 3'd0);
end

// FSM + datapath  (single always block, synchronous reset)
integer i;

always @(posedge clk) begin
    if (rst) begin
        state      <= S_IDLE;
        sample_cnt <= {ADDR_W{1'b0}};
        byte_cnt   <= {ADDR_W{1'b0}};
        bit_cnt    <= 3'd7;
        clk_cnt    <= {CNT_W{1'b0}};
        clk_phase  <= 1'b0;
        spi_clk    <= 1'b0;
        spi_mosi   <= 1'b0;
        spi_cs_n   <= 1'b1;
        tx_done    <= 1'b0;
        busy       <= 1'b0;
        // Clear buffer (synthesis-safe; tools will optimise)
        for (i = 0; i < N; i = i + 1)
            buf_mem[i] <= 8'h00;
    end else begin
        // Default pulse-only signals.
        tx_done <= 1'b0;

        case (state)

            S_IDLE: begin
                spi_clk  <= 1'b0;
                spi_mosi <= 1'b0;
                spi_cs_n <= 1'b1;
                busy     <= 1'b0;

                if (s_valid) begin
                    buf_mem[0] <= s_data;
                    sample_cnt <= {{(ADDR_W-1){1'b0}}, 1'b1}; // Next slot = 1.
                    busy       <= 1'b1;
                    if (s_last) begin
                        // Edge case: N=1 (not typical, but robust)
                        state      <= S_TRANSMIT;
                        byte_cnt   <= {ADDR_W{1'b0}};
                        bit_cnt    <= 3'd7;
                        clk_cnt    <= {CNT_W{1'b0}};
                        clk_phase  <= 1'b0;
                        spi_cs_n   <= 1'b0;
                        spi_mosi   <= s_data[7];
                    end else begin
                        state <= S_COLLECT;
                    end
                end
            end

            // Receive samples from the pipeline into buf_mem.
            // Transmission begins only after s_last.
            S_COLLECT: begin
                if (s_valid) begin
                    buf_mem[sample_cnt] <= s_data;
                    sample_cnt          <= sample_cnt + 1'b1;

                    if (s_last) begin
                        // Buffer complete — begin SPI transmission.
                        state     <= S_TRANSMIT;
                        byte_cnt  <= {ADDR_W{1'b0}};
                        bit_cnt   <= 3'd7;
                        clk_cnt   <= {CNT_W{1'b0}};
                        clk_phase <= 1'b0;
                        spi_cs_n  <= 1'b0;
                        // Pre-drive first bit so it is stable before clk rises.
                        spi_mosi  <= buf_mem[0][7];
                    end
                end
            end

            // SPI Mode 0: CPOL=0, CPHA=0.
            // Phase 0 (clk_phase=0): drive MOSI, then produce rising edge.
            // Phase 1 (clk_phase=1): MCU latches on rise, then falling edge.
            // Clk_cnt counts 0..CLK_DIV-1 within each half-period.
            // On the last count of each half-period we toggle the clock and.
            // Advance the state machine.
            S_TRANSMIT: begin
                if (clk_cnt < (CLK_DIV - 1)) begin
                    clk_cnt <= clk_cnt + 1'b1;
                    // MOSI is already driven; hold steady.
                end else begin
                    // End of this half-period.
                    clk_cnt <= {CNT_W{1'b0}};

                    if (clk_phase == 1'b0) begin
                        // MOSI was already stable; now raise the clock.
                        // MCU latches here (Mode 0).
                        spi_clk   <= 1'b1;
                        clk_phase <= 1'b1;
                    end else begin
                        spi_clk   <= 1'b0;
                        clk_phase <= 1'b0;

                        if (!last_bit) begin
                            // More bits in this byte.
                            bit_cnt  <= bit_cnt - 1'b1;
                            spi_mosi <= buf_mem[byte_cnt][bit_cnt - 1];
                        end else begin
                            // Bit_cnt == 0 — just finished last bit of byte.
                            if (!last_byte) begin
                                // Advance to next byte.
                                byte_cnt <= byte_cnt + 1'b1;
                                bit_cnt  <= 3'd7;
                                spi_mosi <= buf_mem[byte_cnt + 1][7];
                            end else begin
                                // Last bit of last byte done.
                                state    <= S_DONE;
                                spi_cs_n <= 1'b1;
                                spi_mosi <= 1'b0;
                            end
                        end
                    end
                end
            end

            S_DONE: begin
                tx_done    <= 1'b1;
                busy       <= 1'b0;
                sample_cnt <= {ADDR_W{1'b0}};
                state      <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule