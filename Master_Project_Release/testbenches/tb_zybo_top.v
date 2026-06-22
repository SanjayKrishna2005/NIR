`timescale 1ns / 1ps
// Tb_zybo_top_v2.v — Extended self-checking testbench for zybo_top.v.
// TESTS:
// TEST 1  — Single spectrum baseline (ramp data)
// TEST 2  — Immediate second run (stale m_valid / early-completion bug)
// TEST 3  — Different spectrum data (flat)
// TEST 4  — Fourth back-to-back run (regression)
// TEST 5  — ctrl_start held high (ARM forgets to clear)
// TEST 6  — 1-cycle ctrl_start pulse (minimum width)
// TEST 7  — All-zero spectrum (zero std_dev edge case)
// TEST 8  — All-max spectrum (0xFFFF overflow stress)
// TEST 9  — Alternating 0/0xFFFF (maximum variance stress)
// TEST 10 — 10 consecutive back-to-back runs.
// TEST 11 — Reset mid-pipeline then clean run.
// TEST 12 — No spurious ctrl_done during IDLE.
// TEST 13 — OUT_BRAM address coverage (all 224 written exactly once)

module tb_zybo_top;

localparam CLK_PERIOD  = 8;
localparam N_CHANNELS  = 224;
localparam TIMEOUT_CYC = 5_000_000;

// DUT signals.
reg         clk;
reg         rst;

reg  [31:0] in_bram_mem  [0:N_CHANNELS-1];
wire [ 9:0] bram_in_addr;
wire        bram_in_en;
reg  [31:0] bram_in_dout;

reg  [31:0] out_bram_mem [0:N_CHANNELS-1];
wire [31:0] bram_out_din;
wire [ 9:0] bram_out_addr;
wire [ 3:0] bram_out_we;
wire        bram_out_enb;

reg         ctrl_start;
wire        ctrl_done;
wire [3:0]  led;

zybo_top dut (
    .clk          (clk),
    .rst          (rst),
    .bram_in_dout (bram_in_dout),
    .bram_in_addr (bram_in_addr),
    .bram_in_en   (bram_in_en),
    .bram_out_din (bram_out_din),
    .bram_out_addr(bram_out_addr),
    .bram_out_we  (bram_out_we),
    .bram_out_enb (bram_out_enb),
    .ctrl_start   (ctrl_start),
    .ctrl_done    (ctrl_done),
    .led          (led)
);

initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// Simulated BRAMs.
always @(posedge clk)
    if (bram_in_en)
        bram_in_dout <= in_bram_mem[bram_in_addr[9:2]];

always @(posedge clk)
    if (bram_out_we != 4'b0000 && bram_out_enb)
        out_bram_mem[bram_out_addr[9:2]] <= bram_out_din;

// Write counter.
integer write_count;
always @(posedge clk) begin
    if (rst)
        write_count <= 0;
    else if (bram_out_we != 4'b0000 && bram_out_enb)
        write_count <= write_count + 1;
end

// Address written bitmap.
reg addr_written [0:N_CHANNELS-1];
integer aw_k;
always @(posedge clk) begin
    if (rst) begin
        for (aw_k = 0; aw_k < N_CHANNELS; aw_k = aw_k + 1)
            addr_written[aw_k] <= 1'b0;
    end else if (bram_out_we != 4'b0000 && bram_out_enb)
        addr_written[bram_out_addr[9:2]] <= 1'b1;
end

// Early-done flag.
reg early_done_flag;
always @(posedge clk) begin
    if (rst) early_done_flag <= 0;
    else if (ctrl_done && (write_count < N_CHANNELS))
        early_done_flag <= 1'b1;
end

// Scoreboard.
integer fail_count;
integer i;

// Tasks.
task load_ramp;
    input [15:0] base;
    input [15:0] step;
    integer k;
    begin
        for (k = 0; k < N_CHANNELS; k = k + 1)
            in_bram_mem[k] = {16'd0, base + k[15:0] * step};
    end
endtask

task load_flat;
    input [15:0] val;
    integer k;
    begin
        for (k = 0; k < N_CHANNELS; k = k + 1)
            in_bram_mem[k] = {16'd0, val};
    end
endtask

task load_alt;
    integer k;
    begin
        for (k = 0; k < N_CHANNELS; k = k + 1)
            in_bram_mem[k] = (k % 2 == 0) ? 32'd0 : 32'h0000FFFF;
    end
endtask

task fill_out;
    input [31:0] val;
    integer k;
    begin
        for (k = 0; k < N_CHANNELS; k = k + 1)
            out_bram_mem[k] = val;
    end
endtask

task clear_trackers;
    integer k;
    begin
        @(negedge clk);
        write_count     = 0;
        early_done_flag = 0;
        for (k = 0; k < N_CHANNELS; k = k + 1)
            addr_written[k] = 0;
    end
endtask

task run_std;
    output integer cyc;
    integer t;
    begin
        cyc = 0;
        ctrl_start = 0;
        repeat(4) @(posedge clk);
        @(negedge clk); ctrl_start = 1;
        t = 0;
        while (!ctrl_done && t < TIMEOUT_CYC) begin
            @(posedge clk); t = t + 1;
        end
        cyc = t;
        @(negedge clk); ctrl_start = 0;
        repeat(10) @(posedge clk);
    end
endtask

task check_all;
    input [8*32:1] nm;
    input integer  cyc;
    input [31:0]   sent;
    integer k; integer rem; integer miss;
    begin
        // Timeout.
        if (cyc >= TIMEOUT_CYC) begin
            $display("FAIL [%0s] TIMEOUT", nm); fail_count=fail_count+1;
        end else $display("PASS [%0s] done in %0d cycles", nm, cyc);

        // Early done.
        if (early_done_flag) begin
            $display("FAIL [%0s] EARLY-DONE BUG (write_count=%0d at done)", nm, write_count);
            fail_count=fail_count+1;
        end else $display("PASS [%0s] no early-done", nm);

        // Write count.
        if (write_count != N_CHANNELS) begin
            $display("FAIL [%0s] write_count=%0d expected=%0d", nm, write_count, N_CHANNELS);
            fail_count=fail_count+1;
        end else $display("PASS [%0s] write_count=%0d", nm, N_CHANNELS);

        // Sentinel check.
        rem = 0;
        for (k=0; k<N_CHANNELS; k=k+1)
            if (out_bram_mem[k]==sent) rem=rem+1;
        if (rem>0) begin
            $display("FAIL [%0s] %0d words still sentinel 0x%08X", nm, rem, sent);
            fail_count=fail_count+1;
        end else $display("PASS [%0s] all words overwritten", nm);

        // Ctrl_done deasserted.
        repeat(10) @(posedge clk);
        if (ctrl_done) begin
            $display("FAIL [%0s] ctrl_done stuck high", nm); fail_count=fail_count+1;
        end else $display("PASS [%0s] ctrl_done deasserted", nm);

        // Address coverage.
        miss = 0;
        for (k=0; k<N_CHANNELS; k=k+1)
            if (!addr_written[k]) miss=miss+1;
        if (miss>0) begin
            $display("FAIL [%0s] %0d addresses never written", nm, miss);
            fail_count=fail_count+1;
        end else $display("PASS [%0s] all 224 addresses written", nm);
    end
endtask

// Test variables.
integer cyc;
integer j;
integer pass10;
reg [7:0] hit [0:N_CHANNELS-1];
integer dup_count;
integer t_inner;

initial begin
    $dumpfile("tb_zybo_top_v2.vcd");
    $dumpvars(0, tb_zybo_top);

    fail_count = 0;
    ctrl_start = 0;
    rst        = 1;
    for (i=0; i<N_CHANNELS; i=i+1) begin
        in_bram_mem[i]=32'd0; out_bram_mem[i]=32'hDEADBEEF; addr_written[i]=0;
    end

    repeat(20) @(posedge clk); rst=0; repeat(10) @(posedge clk);

    $display("================================================");
    $display(" tb_zybo_top_v2 — Full edge-case regression");
    $display("================================================");

    // TEST 1.
    $display("\n--- TEST 1: Baseline single run ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_ramp(16'd612, 16'd1);
    run_std(cyc); check_all("TEST1", cyc, 32'hDEADBEEF);

    // TEST 2 — stale m_valid (primary bug)
    $display("\n--- TEST 2: Immediate 2nd run (stale m_valid) ---");
    clear_trackers; fill_out(32'hCAFEBABE); load_ramp(16'd612, 16'd1);
    run_std(cyc); check_all("TEST2", cyc, 32'hCAFEBABE);

    // TEST 3 — flat spectrum.
    $display("\n--- TEST 3: Flat spectrum ---");
    clear_trackers; fill_out(32'hBAADF00D); load_flat(16'd1000);
    run_std(cyc); check_all("TEST3", cyc, 32'hBAADF00D);

    // TEST 4 — 4th consecutive.
    $display("\n--- TEST 4: 4th consecutive run ---");
    clear_trackers; fill_out(32'hFEEDFACE); load_ramp(16'd800, 16'd2);
    run_std(cyc); check_all("TEST4", cyc, 32'hFEEDFACE);

    // TEST 5 — ctrl_start held high.
    $display("\n--- TEST 5: ctrl_start held high (ARM forgets to clear) ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_ramp(16'd700, 16'd1);
    ctrl_start=0; repeat(4) @(posedge clk);
    @(negedge clk); ctrl_start=1;
    t_inner=0;
    while (!ctrl_done && t_inner<TIMEOUT_CYC) begin @(posedge clk); t_inner=t_inner+1; end
    repeat(20) @(posedge clk);
    if (!ctrl_done) begin
        $display("FAIL [TEST5] ctrl_done dropped while ctrl_start still high");
        fail_count=fail_count+1;
    end else $display("PASS [TEST5] ctrl_done held while ctrl_start high");
    @(negedge clk); ctrl_start=0; repeat(10) @(posedge clk);
    if (ctrl_done) begin
        $display("FAIL [TEST5] ctrl_done stuck after clear"); fail_count=fail_count+1;
    end else $display("PASS [TEST5] ctrl_done deasserted after clear");
    if (write_count==N_CHANNELS)
        $display("PASS [TEST5] write_count=%0d", N_CHANNELS);
    else begin
        $display("FAIL [TEST5] write_count=%0d", write_count); fail_count=fail_count+1;
    end

    // TEST 6 — 1-cycle pulse.
    $display("\n--- TEST 6: 1-cycle ctrl_start pulse ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_ramp(16'd500, 16'd3);
    ctrl_start=0; repeat(4) @(posedge clk);
    @(negedge clk); ctrl_start=1;
    @(posedge clk); @(negedge clk); ctrl_start=0;
    t_inner=0;
    while (!ctrl_done && t_inner<TIMEOUT_CYC) begin @(posedge clk); t_inner=t_inner+1; end
    if (t_inner>=TIMEOUT_CYC) begin
        $display("FAIL [TEST6] TIMEOUT — 1-cycle pulse not detected"); fail_count=fail_count+1;
    end else $display("PASS [TEST6] 1-cycle pulse detected, done in %0d cycles", t_inner);
    if (write_count==N_CHANNELS)
        $display("PASS [TEST6] write_count=%0d", N_CHANNELS);
    else begin
        $display("FAIL [TEST6] write_count=%0d", write_count); fail_count=fail_count+1;
    end
    @(negedge clk); ctrl_start=0; repeat(10) @(posedge clk);

    // TEST 7 — all-zero spectrum.
    $display("\n--- TEST 7: All-zero spectrum (zero std_dev) ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_flat(16'd0);
    run_std(cyc);
    if (cyc<TIMEOUT_CYC)
        $display("PASS [TEST7] Completed in %0d cycles (no hang)", cyc);
    else begin $display("FAIL [TEST7] TIMEOUT on zero spectrum"); fail_count=fail_count+1; end
    if (write_count==N_CHANNELS)
        $display("PASS [TEST7] write_count=%0d", N_CHANNELS);
    else begin $display("FAIL [TEST7] write_count=%0d", write_count); fail_count=fail_count+1; end

    // TEST 8 — all-max spectrum.
    $display("\n--- TEST 8: All-max spectrum (0xFFFF) ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_flat(16'hFFFF);
    run_std(cyc);
    if (cyc<TIMEOUT_CYC) $display("PASS [TEST8] Completed in %0d cycles", cyc);
    else begin $display("FAIL [TEST8] TIMEOUT"); fail_count=fail_count+1; end
    if (write_count==N_CHANNELS)
        $display("PASS [TEST8] write_count=%0d", N_CHANNELS);
    else begin $display("FAIL [TEST8] write_count=%0d", write_count); fail_count=fail_count+1; end

    // TEST 9 — alternating.
    $display("\n--- TEST 9: Alternating 0/0xFFFF ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_alt;
    run_std(cyc);
    if (cyc<TIMEOUT_CYC) $display("PASS [TEST9] Completed in %0d cycles", cyc);
    else begin $display("FAIL [TEST9] TIMEOUT"); fail_count=fail_count+1; end
    if (write_count==N_CHANNELS)
        $display("PASS [TEST9] write_count=%0d", N_CHANNELS);
    else begin $display("FAIL [TEST9] write_count=%0d", write_count); fail_count=fail_count+1; end

    // TEST 10 — 10 consecutive runs.
    $display("\n--- TEST 10: 10 consecutive runs ---");
    pass10=1;
    for (j=0; j<10; j=j+1) begin
        clear_trackers; fill_out(32'hDEADBEEF);
        load_ramp(16'd600 + j*10, 16'd1);
        run_std(cyc);
        if (cyc>=TIMEOUT_CYC||write_count!=N_CHANNELS||early_done_flag) begin
            $display("  FAIL run %0d cyc=%0d wc=%0d early=%0d",j,cyc,write_count,early_done_flag);
            fail_count=fail_count+1; pass10=0;
        end else
            $display("  PASS run %0d: %0d writes in %0d cycles",j,write_count,cyc);
    end
    if (pass10) $display("PASS [TEST10] All 10 runs clean");

    // TEST 11 — reset mid-pipeline.
    $display("\n--- TEST 11: Reset mid-pipeline ---");
    clear_trackers; fill_out(32'hDEADBEEF); load_ramp(16'd700, 16'd1);
    ctrl_start=0; repeat(4) @(posedge clk);
    @(negedge clk); ctrl_start=1;
    repeat(100) @(posedge clk);
    @(negedge clk); rst=1; ctrl_start=0;
    repeat(20) @(posedge clk); rst=0; repeat(10) @(posedge clk);
    clear_trackers; fill_out(32'hCAFEBABE); load_ramp(16'd612, 16'd1);
    run_std(cyc);
    if (cyc<TIMEOUT_CYC && write_count==N_CHANNELS && !early_done_flag)
        $display("PASS [TEST11] Post-reset run clean (%0d cycles)", cyc);
    else begin
        $display("FAIL [TEST11] Post-reset failed (cyc=%0d wc=%0d early=%0d)",
                 cyc,write_count,early_done_flag);
        fail_count=fail_count+1;
    end

    // TEST 12 — no spurious ctrl_done in IDLE.
    $display("\n--- TEST 12: No spurious ctrl_done during IDLE ---");
    ctrl_start=0; repeat(200) @(posedge clk);
    if (ctrl_done) begin
        $display("FAIL [TEST12] ctrl_done high in IDLE"); fail_count=fail_count+1;
    end else $display("PASS [TEST12] ctrl_done=0 in IDLE");

    // TEST 13 — address coverage (each of 224 written exactly once)
    $display("\n--- TEST 13: OUT_BRAM address coverage ---");
    for (j=0; j<N_CHANNELS; j=j+1) hit[j]=8'd0;
    clear_trackers; fill_out(32'hDEADBEEF); load_ramp(16'd612, 16'd1);
    ctrl_start=0; repeat(4) @(posedge clk);
    @(negedge clk); ctrl_start=1;
    t_inner=0;
    while (!ctrl_done && t_inner<TIMEOUT_CYC) begin
        @(posedge clk);
        if (bram_out_we!=4'b0000 && bram_out_enb)
            hit[bram_out_addr[9:2]] = hit[bram_out_addr[9:2]] + 1;
        t_inner=t_inner+1;
    end
    @(negedge clk); ctrl_start=0; repeat(10) @(posedge clk);
    dup_count=0;
    for (j=0; j<N_CHANNELS; j=j+1) begin
        if (hit[j]==0) begin
            $display("  MISSING addr %0d",j); dup_count=dup_count+1;
        end else if (hit[j]>1) begin
            $display("  DUPLICATE addr %0d written %0d times",j,hit[j]); dup_count=dup_count+1;
        end
    end
    if (dup_count==0) $display("PASS [TEST13] All 224 addresses written exactly once");
    else begin $display("FAIL [TEST13] %0d anomalies",dup_count); fail_count=fail_count+1; end

    // Summary.
    $display("\n================================================");
    $display(" FINAL RESULTS");
    $display("================================================");
    if (fail_count==0)
        $display(" ALL 13 TESTS PASSED");
    else
        $display(" %0d FAILURE(S)", fail_count);
    $display("================================================");
    $finish;
end

initial begin
    #(TIMEOUT_CYC*CLK_PERIOD*20);
    $display("FATAL: global watchdog"); $finish;
end

endmodule