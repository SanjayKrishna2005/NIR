// =============================================================================
// File Name   : vio_hardware_testbench.v
// Description : Part of the NIR Plastic Sorter Machine Learning Pipeline.
//               This module has been optimized for the Artix-7 FPGA Architecture.
//               (100% Pure Hardware Digital Logic)
// =============================================================================
`timescale 1ns / 1ps

module vio_hardware_testbench (
    input  wire clk,
    input  wire rst_n
);

    // =========================================================================
    // VIO Signals
    // =========================================================================
    wire vio_start;         // VIO Output Probe 0 (1-bit)
    
    reg  test_done;         // VIO Input Probe 0 (1-bit)
    reg  [7:0] current_spec;// VIO Input Probe 1 (8-bit)
    reg  [7:0] match_count; // VIO Input Probe 2 (8-bit)
    wire [6:0] accuracy_pct;// VIO Input Probe 3 (7-bit)

    // Accuracy is just (match_count / 200) * 100 = match_count / 2
    assign accuracy_pct = match_count >> 1;

    // =========================================================================
    // VIO IP Instantiation
    // =========================================================================
    vio_0 u_vio (
        .clk(clk),
        .probe_in0(test_done),        // 1-bit
        .probe_in1(current_spec),     // 8-bit
        .probe_in2(match_count),      // 8-bit
        .probe_in3(accuracy_pct),     // 7-bit
        .probe_out0(vio_start)        // 1-bit
    );

    // =========================================================================
    // Internal ROMs
    // =========================================================================
    reg [15:0] features_rom [0:44799]; // 200 * 224
    reg [2:0]  classes_rom  [0:199];   // 200

    initial begin
        $readmemh("test_200_features.hex", features_rom);
        $readmemh("test_200_classes.hex", classes_rom);
    end

    // =========================================================================
    // DUT: nir_sorter_top
    // =========================================================================
    reg         s_valid;
    reg  [15:0] s_data;
    reg         s_last;

    wire [2:0]  class_id;
    wire        class_valid;
    wire        dut_busy;
    wire        result_valid;

    nir_sorter_top u_sorter (
        .clk         (clk),
        .rst         (~rst_n), // Active high reset for DUT
        .mode_filter (1'b1),   // Enable SG Filter
        .scale_in    (8'd110),
        .scale_we    (1'b0),
        .s_valid     (s_valid),
        .s_data      (s_data),
        .s_last      (s_last),
        .class_id    (class_id),
        .class_valid (class_valid),
        .busy        (dut_busy),
        .result_valid(result_valid)
    );

    // =========================================================================
    // Hardware Testbench FSM
    // =========================================================================
    localparam STATE_IDLE   = 3'd0,
               STATE_STREAM = 3'd1,
               STATE_WAIT   = 3'd2,
               STATE_EVAL   = 3'd3,
               STATE_DONE   = 3'd4;

    reg [2:0]  state;
    reg [7:0]  sample_idx; // 0 to 223
    reg [15:0] rom_addr;   // 0 to 44799

    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= STATE_IDLE;
            current_spec <= 8'd0;
            match_count  <= 8'd0;
            test_done    <= 1'b0;
            s_valid      <= 1'b0;
            s_data       <= 16'd0;
            s_last       <= 1'b0;
            sample_idx   <= 8'd0;
            rom_addr     <= 16'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    s_valid <= 1'b0;
                    s_last  <= 1'b0;
                    if (vio_start) begin
                        // Start a fresh test run
                        current_spec <= 8'd0;
                        match_count  <= 8'd0;
                        test_done    <= 1'b0;
                        sample_idx   <= 8'd0;
                        rom_addr     <= 16'd0;
                        state        <= STATE_STREAM;
                    end
                end

                STATE_STREAM: begin
                    s_valid <= 1'b1;
                    s_data  <= features_rom[rom_addr];
                    
                    if (sample_idx == 8'd223) begin
                        s_last     <= 1'b1;
                        state      <= STATE_WAIT;
                    end else begin
                        s_last     <= 1'b0;
                        sample_idx <= sample_idx + 1'b1;
                        rom_addr   <= rom_addr + 1'b1;
                    end
                end

                STATE_WAIT: begin
                    s_valid <= 1'b0;
                    s_last  <= 1'b0;
                    if (class_valid) begin
                        // Result is ready
                        state <= STATE_EVAL;
                    end
                end

                STATE_EVAL: begin
                    if (class_id == classes_rom[current_spec]) begin
                        match_count <= match_count + 1'b1;
                    end
                    
                    if (current_spec == 8'd199) begin
                        test_done <= 1'b1;
                        state     <= STATE_DONE;
                    end else begin
                        current_spec <= current_spec + 1'b1;
                        sample_idx   <= 8'd0;
                        rom_addr     <= (current_spec + 1'b1) * 224; // point to next spectrum
                        state        <= STATE_STREAM;
                    end
                end

                STATE_DONE: begin
                    // Stay here until user lowers and raises vio_start again
                    if (!vio_start) begin
                        state <= STATE_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
