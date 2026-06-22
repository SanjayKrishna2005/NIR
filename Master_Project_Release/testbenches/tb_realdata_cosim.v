// Tb_realdata_cosim.v  — v6.
// CHANGES vs v5:
// 1. classify.py command updated: no more --weights (MLP .npz).
// Now uses --weights_hex / --biases_hex pointing at LinearSVC Q15 exports.
// From train_svm_rtl.py (weights.hex, biases.hex).
// 2. gen_spectrum_hex.py command updated: --csv / --n / --outdir only.
// (removed --balanced flag which is now always-on by default).
// 3. SVM model comment block added — documents inference chain.
// 4. SCALE register value comment updated to match quantiser.v default=110.
// 5. All other logic (SPI capture, tasks, watchdog) unchanged from v5.
`timescale 1ns/1ps

module tb_realdata_cosim;

    parameter integer N_SAMPLES  = 250;
    parameter integer N_CHANNELS = 224;
    parameter integer CLK_PERIOD = 10;

    // DUT signals.
    reg         clk = 0, rst = 1;
    reg         adc_valid = 0, adc_last = 0;
    reg  [15:0] adc_data  = 0;
    wire        feat_spi_clk, feat_spi_mosi, feat_spi_cs_n;
    wire        led_busy, led_done;

    reg         cfg_spi_clk  = 0;
    reg         cfg_spi_mosi = 0;
    reg         cfg_spi_cs_n = 1;

    // DUT.
    accel_top dut (
        .clk           (clk),
        .rst           (rst),
        .adc_valid     (adc_valid),
        .adc_data      (adc_data),
        .adc_last      (adc_last),
        .feat_spi_clk  (feat_spi_clk),
        .feat_spi_mosi (feat_spi_mosi),
        .feat_spi_cs_n (feat_spi_cs_n),
        .cfg_spi_clk   (cfg_spi_clk),
        .cfg_spi_mosi  (cfg_spi_mosi),
        .cfg_spi_cs_n  (cfg_spi_cs_n),
        .led_busy      (led_busy),
        .led_done      (led_done)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // SPI capture — samples feat_spi_mosi on every rising edge of feat_spi_clk.
    // Stores 224 bytes into spi_rx_buf[0..223], written to features_NNN.hex.
    reg  [7:0]  spi_rx_buf   [0:N_CHANNELS-1];
    reg  [7:0]  spi_shift    = 0;
    integer     spi_bit_cnt  = 0;
    integer     spi_byte_cnt = 0;
    reg         spi_active   = 0;
    reg         spi_clk_prev = 0;

    wire spi_clk_rise = feat_spi_clk & ~spi_clk_prev;

    always @(posedge clk) begin
        spi_clk_prev <= feat_spi_clk;

        if (!feat_spi_cs_n && !spi_active) begin
            spi_active   <= 1;
            spi_bit_cnt  <= 0;
            spi_byte_cnt <= 0;
            spi_shift    <= 0;
        end

        if (feat_spi_cs_n && spi_active)
            spi_active <= 0;

        if (spi_active && spi_clk_rise) begin
            spi_shift <= {spi_shift[6:0], feat_spi_mosi};
            if (spi_bit_cnt == 7) begin
                spi_rx_buf[spi_byte_cnt] <= {spi_shift[6:0], feat_spi_mosi};
                spi_bit_cnt  <= 0;
                spi_byte_cnt <= spi_byte_cnt + 1;
            end else begin
                spi_bit_cnt <= spi_bit_cnt + 1;
            end
        end
    end

    // Task: send 16-bit config SPI frame, Mode 0, MSB first.
    // Half-period = 8 negedge cycles (well above 3-cycle synchroniser minimum)
    // We instantiate the configuration registers here.
    // 0x00  MODE_FILTER [0]   0=MA  1=SG (default=1)
    // 0x01  SCALE       [7:0] quantiser scale (default=110 = 0x6E)
    // 0x02  START       [0]   write-1 pulse.
    // Frame encoding: {1'b1, 7'b addr, 8'b data}
    // SCALE=110  : addr=0x01 data=0x6E → frame=0x816E.
    // START=1    : addr=0x02 data=0x01 → frame=0x8201.
    task send_cfg_spi;
        input [15:0] frame;
        integer b;
        begin
            @(negedge clk); cfg_spi_cs_n = 0;
            repeat(4) @(negedge clk);

            for (b = 15; b >= 0; b = b - 1) begin
                @(negedge clk);
                cfg_spi_mosi = frame[b];
                cfg_spi_clk  = 0;
                repeat(7) @(negedge clk);

                @(negedge clk);
                cfg_spi_clk = 1;
                repeat(7) @(negedge clk);

                @(negedge clk);
                cfg_spi_clk = 0;
            end

            repeat(4) @(negedge clk);
            @(negedge clk); cfg_spi_cs_n = 1;
            cfg_spi_mosi = 0;
            cfg_spi_clk  = 0;

            // Wait for synchroniser + register write (20 sys_clk cycles)
            repeat(20) @(posedge clk);
        end
    endtask

    // Task: send spectrum — drives adc_valid/adc_data/adc_last for 224 samples.
    reg [15:0] spectrum [0:N_CHANNELS-1];

    task send_spectrum;
        integer j;
        begin
            @(negedge clk);
            for (j = 0; j < N_CHANNELS; j = j + 1) begin
                @(negedge clk);
                adc_valid = 1;
                adc_data  = spectrum[j];
                adc_last  = (j == N_CHANNELS-1) ? 1 : 0;
                @(posedge clk);
            end
            @(negedge clk);
            adc_valid = 0;
            adc_last  = 0;
        end
    endtask

    // Task: wait until all 224 bytes captured OR timeout.
    // Step 1 — wait for feat_spi_cs_n LOW  (SPI TX burst started)
    // Step 2 — wait for feat_spi_cs_n HIGH (all 224 bytes shifted out)
    // Step 3 — drain 50 cycles  (capture always block processes last byte)
    // Step 4 — verify spi_byte_cnt == 224.
    integer timeout;
    integer sample_idx;

    task wait_capture_done;
        begin
            // Step 1.
            timeout = 0;
            while (feat_spi_cs_n && timeout < 500000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 500000)
                $display("[WARN] Timeout: feat_spi_cs_n never LOW on sample %0d  started=%b",
                         sample_idx, dut.started);

            // Step 2.
            timeout = 0;
            while (!feat_spi_cs_n && timeout < 500000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 500000)
                $display("[WARN] Timeout: feat_spi_cs_n never HIGH on sample %0d", sample_idx);

            // Step 3.
            repeat(50) @(posedge clk);

            // Step 4.
            if (spi_byte_cnt != N_CHANNELS)
                $display("[WARN] sample %0d: expected %0d bytes, got %0d",
                         sample_idx, N_CHANNELS, spi_byte_cnt);
        end
    endtask

    // Task: write features_NNN.hex — 224 INT8 bytes from RTL pipeline output.
    // These files are read directly by classify.py for LinearSVC inference.
    integer     out_file;
    reg [127:0] fname;

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
                    $fdisplay(out_file, "%02X", spi_rx_buf[k]);
                $fclose(out_file);
            end
        end
    endtask

    // Main sequence.
    // RTL pipeline per spectrum (~1283 cycles @ 100 MHz ≈ 12.8 µs):
    // Dark_correct     :    1 cycle.
    // Baseline_correct :  448 cycles  (224 accum + 224 output)
    // Filter_stage(SG) :   ~3 cycles  (warmup + streaming)
    // Snv_norm         :  ~830 cycles (pass1/pass2/sqrt/recip/pass3)
    // Quantiser        :    1 cycle.
    // Finally, we instantiate the SPI transmitter module.
    // 14336 × 4 sys_clk ≈ 57344 cycles @ CLK_DIV=4.
    // AI model (LinearSVC, weights in outputs/):
    // Classifier  : LinearSVC  C=0.01  class_weight=balanced.
    // Input       : 224 × INT8  (directly from quantiser — no PCA/MLP)
    // Weights     : Q15 INT16  (weights.hex  5×224 values)
    // Biases      : Q15 INT32  (biases.hex   5 values)
    // Inference   : score[c] = dot(W_q15[c,:], x_int8) + b_q15[c]
    // Class    = argmax(score) + 1  (1-indexed)
    // Performance : low-noise 99.18%  high-noise 92.84%.
    initial begin
        $display("====================================================");
        $display(" Real-data co-simulation — %0d spectra", N_SAMPLES);
        $display(" AI model : LinearSVC Q15  (weights.hex / biases.hex)");
        $display("====================================================");

        rst = 1;
        repeat(20) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat(10) @(posedge clk);

        // We instantiate the configuration registers here.
        // Matches quantiser.v default and train_svm_rtl.py --scale 110.
        $display("[INIT] Writing SCALE=110 (0x6E) to config_regs ...");
        send_cfg_spi(16'h816E);

        for (sample_idx = 0; sample_idx < N_SAMPLES; sample_idx = sample_idx + 1) begin

            $sformat(fname, "spectrum_%03d.hex", sample_idx);
            $readmemh(fname, spectrum);
            $display("[%0d/%0d] Processing %0s ...", sample_idx+1, N_SAMPLES, fname);

            // Reset SPI capture counters BEFORE sending START.
            spi_byte_cnt = 0;
            spi_bit_cnt  = 0;

            // Send START pulse (addr=0x02, data=0x01 → frame=0x8201)
            // Sets dut.started=1 → pipe_s_valid = adc_valid & started.
            send_cfg_spi(16'h8201);

            // Feed 224 raw ADC samples through pipeline.
            send_spectrum;

            // Wait for full 224-byte SPI capture (CS low→high + 50-cycle drain)
            wait_capture_done;

            write_features(sample_idx);
            $display("       → features_%03d.hex written (%0d bytes), byte[0]=0x%02X",
                     sample_idx, spi_byte_cnt, spi_rx_buf[0]);

            // Finally, we instantiate the SPI transmitter module.
            repeat(200) @(posedge clk);
        end

        $display("====================================================");
        $display(" Done. Classify outputs with LinearSVC Q15:");
        $display("");
        $display("   python3 classify.py \\");
        $display("       --features_dir . \\");
        $display("       --labels       labels.txt \\");
        $display("       --weights_hex  outputs/weights.hex \\");
        $display("       --biases_hex   outputs/biases.hex");
        $display("");
        $display(" Or use sklearn pkl directly (float reference):");
        $display("   python3 classify.py \\");
        $display("       --features_dir . \\");
        $display("       --labels       labels.txt \\");
        $display("       --pkl          outputs/svm_fpga_model.pkl");
        $display("====================================================");
        $finish;
    end

    // Global watchdog — 2 seconds sim time (200M cycles @ 100 MHz)
    initial begin
        #20000000000;
        $display("[FATAL] Global watchdog expired");
        $finish;
    end

endmodule