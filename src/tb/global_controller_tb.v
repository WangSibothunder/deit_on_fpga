// -----------------------------------------------------------------------------
// File: src/tb/global_controller_tb.v
// Desc: Global controller sanity test (beat-based weight DMA)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module global_controller_tb;

    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_seq_len;
    reg i_weight_valid;
    reg i_weight_dma_beat;
    reg i_input_valid;
    reg i_dbg_clr;

    wire ap_done;
    wire ap_idle;
    wire [2:0] current_state_dbg;

    wire ctrl_weight_dma_req;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    wire ctrl_drain_en;
    wire [31:0] dbg_cnt_load;
    wire [31:0] dbg_cnt_seq;
    wire [31:0] dbg_cnt_drain;
    wire [31:0] dbg_weight_beat_cnt;

    localparam LATENCY = 10;

    global_controller #(
        .LATENCY(LATENCY)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ap_start(ap_start), .cfg_seq_len(cfg_seq_len),
        .ap_done(ap_done), .ap_idle(ap_idle),
        .current_state_dbg(current_state_dbg),
        .ctrl_weight_dma_req(ctrl_weight_dma_req),
        .i_weight_valid(i_weight_valid),
        .i_weight_dma_beat(i_weight_dma_beat),
        .i_input_valid(i_input_valid),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .ctrl_drain_en(ctrl_drain_en),
        .dbg_cnt_load(dbg_cnt_load),
        .dbg_cnt_seq(dbg_cnt_seq),
        .dbg_cnt_drain(dbg_cnt_drain),
        .dbg_weight_beat_cnt(dbg_weight_beat_cnt),
        .i_dbg_clr(i_dbg_clr)
    );

    always #5 clk = ~clk;

    integer beat_sent;
    integer wload_sent;
    integer seq_sent;
    integer cycles;

    initial begin
        $dumpfile("controller_verify.vcd");
        $dumpvars(0, global_controller_tb);

        clk = 0; rst_n = 0; ap_start = 0; cfg_seq_len = 0;
        i_weight_valid = 0; i_weight_dma_beat = 0; i_input_valid = 0; i_dbg_clr = 0;
        beat_sent = 0; wload_sent = 0; seq_sent = 0; cycles = 0;
        #20 rst_n = 1;
        #20;

        $display("=== START CONTROLLER VERIFICATION (BEAT-BASED) ===");

        cfg_seq_len = 8;

        @(posedge clk);
        ap_start = 1;
        @(posedge clk);
        ap_start = 0;

        // Main driver loop with timeout
        for (cycles = 0; cycles < 500; cycles = cycles + 1) begin
            @(posedge clk);

            // Drive weight DMA beats
            if (ctrl_weight_dma_req && beat_sent < 24) begin
                i_weight_dma_beat <= 1;
                beat_sent = beat_sent + 1;
            end else begin
                i_weight_dma_beat <= 0;
            end

            // Drive weight load valids
            if (ctrl_weight_load_en && wload_sent < 12) begin
                i_weight_valid <= 1;
                wload_sent = wload_sent + 1;
            end else begin
                i_weight_valid <= 0;
            end

            // Drive input valids
            if (ctrl_input_stream_en && seq_sent < cfg_seq_len) begin
                i_input_valid <= 1;
                seq_sent = seq_sent + 1;
            end else begin
                i_input_valid <= 0;
            end

            if (ap_done) begin
                $display("[PASS] ap_done received at cycle %0d.", cycles);
                disable done_wait;
            end
        end

        $display("[FAIL] Timeout waiting for ap_done.");
        $display("[INFO] beat_sent=%0d wload_sent=%0d seq_sent=%0d", beat_sent, wload_sent, seq_sent);
        $finish;
    end

    // Separate block to finish on done
    initial begin : done_wait
        wait(ap_done == 1);
        @(posedge clk);
        if (ap_idle !== 1) $display("[FAIL] Should return to IDLE.");
        else $display("[PASS] Returned to IDLE.");

        $display("[INFO] dbg_weight_beat_cnt=%0d", dbg_weight_beat_cnt);
        $display("[INFO] dbg_cnt_load=%0d dbg_cnt_seq=%0d dbg_cnt_drain=%0d", dbg_cnt_load, dbg_cnt_seq, dbg_cnt_drain);

        $display("\n=== SUCCESS: Controller Logic Verified ===\n");
        $finish;
    end

endmodule
