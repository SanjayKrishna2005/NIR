// We instantiate the configuration registers here.
// Project : FPGA NIR Spectroscopy Preprocessing Accelerator.
// Purpose : SPI-slave register file. MCU writes configuration parameters.
// Over SPI Mode 0. FPGA pipeline reads registers combinationally.
// SPI Frame (16 bits, MSB first):
// [15]    : direction (1=write, 0=read; only writes handled here)
// [14:8]  : 7-bit register address.
// [7:0]   : 8-bit data.
// Register map:
// 0x00  MODE_FILTER [0]   0=moving-avg  1=Savitzky-Golay (default)
// 0x01  SCALE       [7:0] quantiser scale factor          (default 110)
// 0x02  START       [0]   write-1 pulse; auto-clears after 1 sys_clk cycle.
// 0x03  STATUS      [1:0] read-only: bit0=pipeline_busy  bit1=tx_done.
// Clock domains.
// Sys_clk : all register logic.
// Spi_clk : asynchronous; edge-detected via 2-flop synchroniser.

`timescale 1ns/1ps

module config_regs (
    input  wire        clk,
    input  wire        rst,

    input  wire        spi_clk,
    input  wire        spi_mosi,
    input  wire        spi_cs_n,

    output reg         mode_filter,
    output reg  [7:0]  scale,
    output reg         start,

    input  wire        pipeline_busy,
    input  wire        tx_done
);

    // 2-flop synchronisers.

    reg [1:0] spi_clk_sync;
    always @(posedge clk) begin
        if (rst) spi_clk_sync <= 2'b00;
        else     spi_clk_sync <= {spi_clk_sync[0], spi_clk};
    end
    wire spi_clk_rise = (spi_clk_sync[1:0] == 2'b01);

    reg [1:0] spi_cs_sync;
    always @(posedge clk) begin
        if (rst) spi_cs_sync <= 2'b11;
        else     spi_cs_sync <= {spi_cs_sync[0], spi_cs_n};
    end
    // Cs_active : cs_n has been low for >= 2 sys_clk cycles (shift enable)
    // Cs_deassert: cs_n rising edge -- sync[1]=0(was low), sync[0]=1(now high)
    // End-of-transaction, latch the completed frame.
    wire cs_active   = ~spi_cs_sync[1];
    wire cs_deassert = (spi_cs_sync[1:0] == 2'b01);

    reg [1:0] spi_mosi_sync;
    always @(posedge clk) begin
        if (rst) spi_mosi_sync <= 2'b00;
        else     spi_mosi_sync <= {spi_mosi_sync[0], spi_mosi};
    end
    wire mosi_s = spi_mosi_sync[1];

    // 16-bit shift register.
    reg [4:0]  bit_cnt;
    reg [15:0] shift_reg;
    reg        frame_valid;

    always @(posedge clk) begin
        if (rst) begin
            bit_cnt     <= 5'd0;
            shift_reg   <= 16'd0;
            frame_valid <= 1'b0;
        end else if (cs_deassert) begin
            // End of transaction: reset counter for next frame.
            // Keep shift_reg and frame_valid stable so the write block.
            // Can sample them on this same cycle.
            bit_cnt <= 5'd0;
        end else if (cs_active && spi_clk_rise) begin
            if (bit_cnt < 5'd16) begin
                shift_reg <= {shift_reg[14:0], mosi_s};
                bit_cnt   <= bit_cnt + 5'd1;
                if (bit_cnt == 5'd15)
                    frame_valid <= 1'b1;
            end
        end else if (!cs_active && !cs_deassert) begin
            // CS has been idle for >2 cycles -- safe to clear state.
            frame_valid <= 1'b0;
            shift_reg   <= 16'd0;
        end
    end

    // Register decode and write.
    wire        frame_dir  = shift_reg[15];
    wire [6:0]  frame_addr = shift_reg[14:8];
    wire [7:0]  frame_data = shift_reg[7:0];

    localparam ADDR_MODE_FILTER = 7'h00;
    localparam ADDR_SCALE       = 7'h01;
    localparam ADDR_START       = 7'h02;
    localparam ADDR_STATUS      = 7'h03;

    always @(posedge clk) begin
        if (rst) begin
            mode_filter <= 1'b1;
            scale       <= 8'd110;
            start       <= 1'b0;
        end else begin
            start <= 1'b0;
            if (cs_deassert && frame_valid && frame_dir) begin
                case (frame_addr)
                    ADDR_MODE_FILTER: mode_filter <= frame_data[0];
                    ADDR_SCALE:       scale       <= frame_data;
                    ADDR_START:       start       <= frame_data[0];
                    ADDR_STATUS:      ;
                    default:          ;
                endcase
            end
        end
    end

    // STATUS is combinational passthrough (pipeline_busy, tx_done used directly.
    // By downstream logic; MCU read-back path out of scope for this module).

endmodule