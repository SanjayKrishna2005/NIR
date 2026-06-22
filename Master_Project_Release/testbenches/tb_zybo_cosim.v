// Tb_zybo_cosim.v  — v1.
// Co-simulation testbench for zybo_top.v (Zybo Z7-10 top level).
// Replaces tb_realdata_cosim.v which drove accel_top / SPI interface.
// CHANGES vs tb_realdata_cosim.v:
// 1. DUT changed: accel_top → zybo_top.
// 2. All SPI signals removed (feat_spi_*, cfg_spi_*, send_cfg_spi task)
// 3. BRAM simulation added:
// In_bram_mem[0:223]  — TB writes spectrum, DUT reads via bram_in_.
// Feat_buf[0:223]     — TB captures DUT writes via bram_out_.
// 4. Handshake changed: ctrl_start pulse → poll ctrl_done → clear start.
// 5. Output capture: watch bram_out_we, latch bram_out_din at bram_out_addr.
// 6. No config SPI needed — zybo_top hardwires SG-5, scale=110 internally.
// 7. Watchdog tightened: 50M cycles (was 200M; no SPI TX overhead)
// 8. Per-spectrum latency comment updated for new pipeline (no SPI)
// PIPELINE LATENCY (zybo_top, 100 MHz):
// BRAM read + pipeline :  224 + 1283 = ~1507 cycles  (~15.1 µs)
// Ctrl handshake       :    ~5 cycles.
// Total per spectrum   :  ~1600 cycles  → 250 spectra ≈ 400K cycles.
// USAGE (same as before — run from sim_data/ so $readmemh finds hex files):
// Cd sim_data.
// Iverilog -g2012 -o cosim.out \.
// ../tb_zybo_cosim.v \.
// This instantiates the top-level preprocessing pipeline.
// ../dark_correct.v ../baseline_correct.v \.
// ../filter_stage.v ../snv_norm.v ../quantiser.v.
// Vvp cosim.out.
// OUTPUT: features_000.hex ... features_NNN.hex  (224 INT8 bytes each)
// Same format as before — classify.py reads them unchanged.
`timescale 1ns/1ps

module tb_zybo_cosim;

    parameter integer N_SAMPLES  = 250;
    parameter integer N_CHANNELS = 224;
    parameter integer CLK_PERIOD = 10;   // 100 MHz (simulation; real HW = 125 MHz)

    // DUT port signals.
    reg         clk        = 0;
    reg         rst        = 1;

    reg  [15:0] bram_in_dout = 0;      // TB drives this (acts as BRAM output)
    wire [ 7:0] bram_in_addr;          // DUT drives address to read.
    wire        bram_in_en;            // DUT asserts when it wants to read.

    wire [ 7:0] bram_out_din;          // INT8 byte the DUT is writing.
    wire [ 7:0] bram_out_addr;         // Address DUT is writing to.
    wire        bram_out_we;           // DUT asserts write-enable.

    reg         ctrl_start = 0;        // TB asserts to start a spectrum.
    wire        ctrl_done;             // DUT asserts when features ready.

    wire [3:0]  led;

    // DUT instantiation.
    zybo_top dut (
        .clk          (clk),
        .rst          (rst),
        .bram_in_dout (bram_in_dout),
        .bram_in_addr (bram_in_addr),
        .bram_in_en   (bram_in_en),
        .bram_out_din (bram_out_din),
        .bram_out_addr(bram_out_addr),
        .bram_out_we  (bram_out_we),
        .ctrl_start   (ctrl_start),
        .ctrl_done    (ctrl_done),
        .led          (led)
    );

    // Clock.
    always #(CLK_PERIOD/2) clk = ~clk;

    // Simulated in_bram.
    // In_bram_mem[0:223] holds the current spectrum (16-bit raw ADC).
    // When the DUT asserts bram_in_en, we present in_bram_mem[bram_in_addr]
    // On bram_in_dout the NEXT cycle (1-cycle read latency, matching real BRAM).
    reg [15:0] in_bram_mem [0:N_CHANNELS-1];

    always @(posedge clk) begin
        if (bram_in_en)
            bram_in_dout <= in_bram_mem[bram_in_addr];
        // When not enabled, hold last value (matches BRAM behaviour)
    end

    // Output capture buffer.
    // Feat_buf[0:223] accumulates INT8 bytes as the DUT writes them.
    // Written to features_NNN.hex after ctrl_done.
    reg [7:0] feat_buf [0:N_CHANNELS-1];

    always @(posedge clk) begin
        if (bram_out_we)
            feat_buf[bram_out_addr] <= bram_out_din;
    end

    // Task: load spectrum_NNN.hex → in_bram_mem.
    // Identical $readmemh call pattern to the old testbench.
    reg [127:0] fname;
    integer     sample_idx;

    task load_spectrum;
        input integer idx;
        begin
            $sformat(fname, "spectrum_%03d.hex", idx);
            $readmemh(fname, in_bram_mem);
        end
    endtask

    // Task: run one spectrum through the pipeline.
    // Step 1 — assert ctrl_start (rising edge triggers DUT FSM)
    // Step 2 — wait for ctrl_done (DUT enters S_DONE and asserts done)
    // Step 3 — clear ctrl_start (DUT returns to S_IDLE)
    // Step 4 — give 5 cycles for DUT to register the deassert.
    // Timeout: 10000 cycles >> max pipeline latency of ~1600 cycles.
    // If ctrl_done never arrives the watchdog below catches it.
    integer timeout;

    task run_pipeline;
        begin
            // Step 1: assert start (rising edge)
            @(negedge clk);
            ctrl_start = 1;

            // Step 2: wait for ctrl_done.
            timeout = 0;
            @(posedge clk);  // Give DUT one cycle to see rising edge.
            while (!ctrl_done && timeout < 10000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 10000)
                $display("[WARN] sample %0d: ctrl_done timeout after %0d cycles",
                         sample_idx, timeout);

            // Step 3: clear start (DUT in S_DONE will return to S_IDLE)
            @(negedge clk);
            ctrl_start = 0;

            // Step 4: drain 5 cycles.
            repeat(5) @(posedge clk);
        end
    endtask

    // Task: write features_NNN.hex from feat_buf.
    // Same format as before — classify.py reads INT8 as 2-digit hex.
    integer out_file;

    task write_features;
        input integer idx;
        integer k;
        begin
            $sformat(fname, "features_%03d.hex", idx);
            out_file = $fopen(fname, "w");
            if (out_file == 0) begin
                $display("[ERROR] Cannot open %0s", fname);
            end else begin
                for (k = 0; k < N_CHANNELS; k = k + 1)
                    $fdisplay(out_file, "%02X", feat_buf[k]);
                $fclose(out_file);
            end
        end
    endtask

    // Main sequence.
    initial begin
        $display("====================================================");
        $display(" zybo_top co-simulation — %0d spectra", N_SAMPLES);
        $display(" Pipeline : dark→baseline→SG-5→SNV→Q8  (no deriv2)");
        $display(" Config   : mode=SG-5  scale=110  (hardwired in RTL)");
        $display("====================================================");

        // Reset.
        rst = 1;
        repeat(20) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat(10) @(posedge clk);

        // No SPI config needed — zybo_top hardwires SG-5 and scale=110.

        for (sample_idx = 0; sample_idx < N_SAMPLES; sample_idx = sample_idx + 1) begin

            // 1. Load raw ADC hex into simulated in_bram.
            load_spectrum(sample_idx);
            $display("[%0d/%0d] Loaded spectrum_%03d.hex → running pipeline ...",
                     sample_idx+1, N_SAMPLES, sample_idx);

            // 2. Run pipeline (start → wait done → clear)
            run_pipeline;

            // 3. Write features_NNN.hex.
            write_features(sample_idx);
            $display("       → features_%03d.hex written  feat[0]=0x%02X  feat[1]=0x%02X",
                     sample_idx, feat_buf[0], feat_buf[1]);

            // 4. Small idle gap — ensures DUT is back in S_IDLE.
            repeat(20) @(posedge clk);

        end

        $display("====================================================");
        $display(" Done. Classify with CNN+SVM:");
        $display("");
        $display("   python3 classify.py \\");
        $display("       --features_dir . \\");
        $display("       --labels       labels.txt \\");
        $display("       --backbone_pt  nir_cnn_backbone.pt \\");
        $display("       --pipeline_pkl nir_svm_pipeline.pkl");
        $display("====================================================");
        $finish;
    end

    // Global watchdog — 50M cycles.
    // 250 spectra × ~1600 cycles = ~400K cycles needed.
    // 50M gives 125× headroom; catches infinite loops immediately.
    initial begin
        #(50_000_000 * CLK_PERIOD);
        $display("[FATAL] Global watchdog expired (50M cycles)");
        $finish;
    end

endmodule