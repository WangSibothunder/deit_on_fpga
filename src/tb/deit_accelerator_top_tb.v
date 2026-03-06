// -----------------------------------------------------------------------------
// File: src/tb/deit_accelerator_top_tb.v
// Description: Top-level verification with arbitrary M/K/N (padding + checkpoints)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module deit_accelerator_top_tb;

    // --- 1. Parameters and Clock ---
    localparam C_S_AXI_DATA_WIDTH = 32;
    localparam C_S_AXI_ADDR_WIDTH = 6;
    localparam ARRAY_ROW = 12;
    localparam ARRAY_COL = 16;

    localparam integer TIMEOUT_CYCLES = 20000;

    // Max sizes for mem files
    localparam integer MAX_INPUT_WORDS      = 10000;
    localparam integer MAX_WEIGHT_WORDS     = 10000;
    localparam integer MAX_OUTPUT_WORDS     = 10000;
    localparam integer MAX_RAM_GOLDEN_WORDS = 200000;

    reg clk, rst_n;
    always #5 clk = ~clk; // 100MHz

    // --- 2. Interface Signals ---
    // AXI-Lite
    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr;
    reg                            s_axi_awvalid;
    wire                           s_axi_awready;
    reg  [31:0]                    s_axi_wdata;
    reg  [3:0]                     s_axi_wstrb;
    reg                            s_axi_wvalid;
    wire                           s_axi_wready;
    wire [1:0]                     s_axi_bresp;
    wire                           s_axi_bvalid;
    reg                            s_axi_bready;

    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_araddr;
    reg                            s_axi_arvalid;
    wire                           s_axi_arready;
    wire [31:0]                    s_axi_rdata;
    wire [1:0]                     s_axi_rresp;
    wire                           s_axi_rvalid;
    reg                            s_axi_rready;

    // AXI-Stream RX (DMA -> FPGA)
    reg  [63:0] axis_in_tdata;
    reg         axis_in_tvalid;
    wire        axis_in_tready;
    reg         axis_in_tlast;

    // AXI-Stream TX (FPGA -> DMA)
    wire [63:0] axis_out_tdata;
    wire        axis_out_tvalid;
    reg         axis_out_tready;
    wire        axis_out_tlast;

    // --- 3. DUT Instance ---
    deit_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        // Lite
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        // Stream
        .axis_in_tdata(axis_in_tdata), .axis_in_tvalid(axis_in_tvalid), .axis_in_tready(axis_in_tready), .axis_in_tlast(axis_in_tlast),
        .axis_out_tdata(axis_out_tdata), .axis_out_tvalid(axis_out_tvalid), .axis_out_tready(axis_out_tready), .axis_out_tlast(axis_out_tlast)
    );

    // --- 4. File Memories ---
    reg [63:0] file_axis_input [0:MAX_INPUT_WORDS-1];
    reg [63:0] file_axis_weight [0:MAX_WEIGHT_WORDS-1];
    reg [63:0] file_axis_golden [0:MAX_OUTPUT_WORDS-1];
    reg [63:0] file_ram_golden [0:MAX_RAM_GOLDEN_WORDS-1];
    reg [31:0] file_config [0:9];

    // --- 5. Runtime Config ---
    integer M_ORIG;
    integer K_ORIG;
    integer N_ORIG;
    integer M_PAD;
    integer K_PAD;
    integer N_PAD;

    integer K_TILES;
    integer N_TILES;
    integer INPUT_WORDS_PER_TILE;
    integer WEIGHT_WORDS_PER_TILE;
    integer OUTPUT_WORDS_PER_TILE;

    initial begin
        $readmemh("src/data/test_data_top/axis_input.mem",  file_axis_input);
        $readmemh("src/data/test_data_top/axis_weight.mem", file_axis_weight);
        $readmemh("src/data/test_data_top/axis_golden.mem", file_axis_golden);
        $readmemh("src/data/test_data_top/ram_golden_c01.mem", file_ram_golden);
        $readmemh("src/data/test_data_top/config.mem", file_config);

        M_ORIG = file_config[4];
        K_ORIG = file_config[5];
        N_ORIG = file_config[6];
        M_PAD  = file_config[7];
        K_PAD  = file_config[8];
        N_PAD  = file_config[9];

        K_TILES = K_PAD / ARRAY_ROW;
        N_TILES = N_PAD / ARRAY_COL;
        INPUT_WORDS_PER_TILE = M_PAD * 3 / 2;
        WEIGHT_WORDS_PER_TILE = 24;
        OUTPUT_WORDS_PER_TILE = M_PAD * 2;

        $display("[CFG] M=%0d K=%0d N=%0d", M_ORIG, K_ORIG, N_ORIG);
        $display("[CFG] M_PAD=%0d K_PAD=%0d N_PAD=%0d", M_PAD, K_PAD, N_PAD);
        $display("[CFG] K_TILES=%0d N_TILES=%0d", K_TILES, N_TILES);
        $display("[CFG] INPUT_WORDS_PER_TILE=%0d", INPUT_WORDS_PER_TILE);
        $display("[CFG] OUTPUT_WORDS_PER_TILE=%0d", OUTPUT_WORDS_PER_TILE);
    end

    // --- 6. AXI Helper Tasks ---
    task axi_lite_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr <= addr; s_axi_awvalid <= 1;
            s_axi_wdata <= data; s_axi_wstrb <= 4'hF; s_axi_wvalid <= 1;
            s_axi_bready <= 1;
            wait(s_axi_awready && s_axi_wready);
            @(posedge clk);
            s_axi_awvalid <= 0; s_axi_wvalid <= 0;
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready <= 0;
        end
    endtask

    task ckpt_a;
        input integer n_idx;
        input integer k_idx;
        input [127:0] tag;
        begin
            $display("[CKPT-A][%s] n=%0d k=%0d state=%0d cnt_load=%0d cnt_seq=%0d cnt_drain=%0d acc_cnt=%0d wv=%b iv=%b dma_req=%b",
                     tag, n_idx, k_idx,
                     dut.u_core.u_controller.state,
                     dut.u_core.u_controller.cnt_load,
                     dut.u_core.u_controller.cnt_seq,
                     dut.u_core.u_controller.cnt_drain,
                     dut.u_core.acc_cnt,
                     dut.wbuf_valid_out,
                     dut.ibuf_valid_out,
                     dut.core_weight_dma_req);
        end
    endtask

    task wait_idle;
        integer cycles;
        begin : WAIT_IDLE
            cycles = 0;
            while (dut.u_core.u_controller.state != 0) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > TIMEOUT_CYCLES) begin
                    $display("[FAIL] Timeout waiting IDLE");
                    ckpt_a(0, 0, "WAIT_IDLE");
                    disable WAIT_IDLE;
                end
            end
        end
    endtask

    task wait_for_dma_req;
        output reg ok;
        integer cycles;
        begin : WAIT_DMA
            ok = 0;
            cycles = 0;
            while (dut.core_weight_dma_req == 0) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > TIMEOUT_CYCLES) begin
                    $display("[FAIL] Timeout waiting DMA_REQ");
                    ckpt_a(0, 0, "WAIT_DMA");
                    ok = 0;
                    disable WAIT_DMA;
                end
            end
            ok = 1;
        end
    endtask

    task wait_for_done;
        integer cycles;
        begin : WAIT_DONE
            cycles = 0;
            while (dut.core_ap_done == 0) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (cycles > TIMEOUT_CYCLES) begin
                    $display("[FAIL] Timeout waiting ap_done");
                    ckpt_a(0, 0, "WAIT_DONE");
                    disable WAIT_DONE;
                end
            end
        end
    endtask

    task send_input_tile;
        input integer k_idx;
        integer i;
        integer base;
        begin
            base = k_idx * INPUT_WORDS_PER_TILE;
            for (i = 0; i < INPUT_WORDS_PER_TILE; i = i + 1) begin
                axis_in_tvalid <= 1;
                axis_in_tdata  <= file_axis_input[base + i];
                axis_in_tlast  <= (i == INPUT_WORDS_PER_TILE - 1);
                @(posedge clk);
            end
            axis_in_tvalid <= 0;
            axis_in_tlast <= 0;
        end
    endtask

    task send_weight_tile;
        input integer n_idx;
        input integer k_idx;
        integer i;
        integer base;
        reg ok_dma;
        begin
            base = (n_idx * K_TILES + k_idx) * WEIGHT_WORDS_PER_TILE;
            wait_for_dma_req(ok_dma);
            if (ok_dma) begin
                for (i = 0; i < WEIGHT_WORDS_PER_TILE; i = i + 1) begin
                    axis_in_tvalid <= 1;
                    axis_in_tdata  <= file_axis_weight[base + i];
                    axis_in_tlast  <= (i == WEIGHT_WORDS_PER_TILE - 1);
                    @(posedge clk);
                end
                axis_in_tvalid <= 0;
                axis_in_tlast <= 0;
            end
        end
    endtask

    task check_acc_ckpt;
        input integer n_idx;
        input integer k_idx;
        integer t;
        integer base;
        reg [63:0] expected;
        reg [31:0] act_c0;
        reg [31:0] act_c1;
        begin
            base = (n_idx * K_TILES + k_idx) * M_PAD;
            for (t = 0; t < 4 && t < M_PAD; t = t + 1) begin
                expected = file_ram_golden[base + t];
                act_c0 = dut.u_core.u_accum.COL_BANK[0].u_bank.mem[t];
                act_c1 = dut.u_core.u_accum.COL_BANK[1].u_bank.mem[t];
                if ({act_c1, act_c0} !== expected) begin
                    $display("[CKPT-B][FAIL] n=%0d k=%0d addr=%0d exp=%h got=%h",
                             n_idx, k_idx, t, expected, {act_c1, act_c0});
                    err_cnt = err_cnt + 1;
                end else begin
                    $display("[CKPT-B][PASS] n=%0d k=%0d addr=%0d val=%h",
                             n_idx, k_idx, t, expected);
                end
            end
        end
    endtask

    task check_output_stream;
        input integer n_idx;
        integer i;
        integer base;
        integer cycles;
        reg [63:0] expected;
        reg [63:0] sampled;
        begin : CHECK_OUT
            $display("[CKPT-C] Checking output stream for N tile %0d", n_idx);
            axis_out_tready <= 1;
            base = n_idx * OUTPUT_WORDS_PER_TILE;

            for (i = 0; i < OUTPUT_WORDS_PER_TILE; i = i + 1) begin : OUT_LOOP
                cycles = 0;
                begin : WAIT_BEAT
                    while (1) begin
                        @(posedge clk);
                        cycles = cycles + 1;
                        if (axis_out_tvalid && axis_out_tready) begin
                            sampled = axis_out_tdata;
                            expected = file_axis_golden[base + i];
                            if (sampled !== expected) begin
                                $display("[FAIL] OUT n=%0d word=%0d exp=%h got=%h", n_idx, i, expected, sampled);
                                err_cnt = err_cnt + 1;
                            end else begin
                                $display("[PASS] OUT n=%0d word=%0d val=%h", n_idx, i, expected);
                            end
                            disable WAIT_BEAT;
                        end
                        if (cycles > TIMEOUT_CYCLES) begin
                            $display("[FAIL] Timeout waiting axis_out_tvalid (n=%0d word=%0d)", n_idx, i);
                            ckpt_a(n_idx, 0, "WAIT_OUT");
                            err_cnt = err_cnt + 1;
                            disable CHECK_OUT;
                        end
                    end
                end
            end
            axis_out_tready <= 0;
        end
    endtask

    task check_outbuf_mem;
        input integer n_idx;
        integer t;
        integer base;
        integer start;
        reg [127:0] expected128;
        reg [127:0] actual128;
        begin : CHECK_OBUF
            $display("[CKPT-D] Checking output buffer FIFO (n=%0d)", n_idx);
            base = n_idx * OUTPUT_WORDS_PER_TILE;
            start = dut.u_out_buf.rd_ptr[7:0];
            for (t = 0; t < 4; t = t + 1) begin
                expected128 = {file_axis_golden[base + t*2 + 1], file_axis_golden[base + t*2]};
                actual128 = dut.u_out_buf.mem[start + t];
                if (actual128 !== expected128) begin
                    $display("[CKPT-D][FAIL] n=%0d row=%0d exp=%h got=%h", n_idx, t, expected128, actual128);
                    err_cnt = err_cnt + 1;
                end else begin
                    $display("[CKPT-D][PASS] n=%0d row=%0d val=%h", n_idx, t, actual128);
                end
            end
        end
    endtask

    task ckpt_outbuf_state;
        input integer n_idx;
        input integer stage;
        begin
            if (stage == 0) begin
                $display("[CKPT-OBUF][BEFORE] n=%0d state=%0d rd=%0d wr=%0d tvalid=%0d",
                         n_idx, dut.u_out_buf.state, dut.u_out_buf.rd_ptr, dut.u_out_buf.wr_ptr, dut.u_out_buf.axis_tvalid);
            end else begin
                $display("[CKPT-OBUF][AFTER ] n=%0d state=%0d rd=%0d wr=%0d tvalid=%0d",
                         n_idx, dut.u_out_buf.state, dut.u_out_buf.rd_ptr, dut.u_out_buf.wr_ptr, dut.u_out_buf.axis_tvalid);
            end
        end
    endtask

    task count_activity;
        input integer n_idx;
        input integer k_idx;
        integer in_valid_cnt;
        integer ppu_cnt;
        begin : COUNT_ACT
            in_valid_cnt = 0;
            ppu_cnt = 0;
            while (!dut.core_ap_done) begin
                @(posedge clk);
                if (dut.u_core.ctrl_input_stream_en && dut.ibuf_valid_out) in_valid_cnt = in_valid_cnt + 1;
                if (dut.ppu_valid) ppu_cnt = ppu_cnt + 1;
            end
            $display("[CKPT-COUNT] n=%0d k=%0d in_valid=%0d ppu_valid=%0d", n_idx, k_idx, in_valid_cnt, ppu_cnt);
        end
    endtask

    integer err_cnt = 0;

    // --- 7. Main Scenario ---
    integer n_idx;
    integer k_idx;
    reg acc_mode;
    reg output_en;

    initial begin
        $dumpfile("src/sim/top_verify.vcd");
        $dumpvars(0, deit_accelerator_top_tb);

        clk = 0; rst_n = 0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_arvalid=0; s_axi_rready=0;
        axis_in_tvalid=0; axis_in_tlast=0; axis_out_tready=0;
        s_axi_awaddr = 0; s_axi_araddr = 0;

        #20 rst_n = 1;
        #50;

        $display("=== START SYSTEM TOP VERIFICATION ===");

        // 1. Config Global & PPU
        axi_lite_write(6'h00, 2);       // soft reset release
        axi_lite_write(6'h08, M_PAD - 1);   // cfg_seq_len = M_PAD - 1 (align with core)
        axi_lite_write(6'h14, file_config[0]);
        axi_lite_write(6'h18, file_config[1]);
        axi_lite_write(6'h1C, file_config[2]);
        axi_lite_write(6'h20, file_config[3]);

        for (n_idx = 0; n_idx < N_TILES; n_idx = n_idx + 1) begin
            $display("\n[TILE] === N=%0d ===", n_idx);
            for (k_idx = 0; k_idx < K_TILES; k_idx = k_idx + 1) begin
                $display("[TILE] -> K=%0d", k_idx);
                acc_mode = (k_idx == 0) ? 0 : 1;
                output_en = (k_idx == K_TILES - 1) ? 1 : 0;

                axi_lite_write(6'h24, output_en);
                axi_lite_write(6'h0C, acc_mode);

                // Preload input in IDLE
                wait_idle();
                send_input_tile(k_idx);

                // Start + send weights on DMA req
                fork
                    begin
                        axi_lite_write(6'h00, 3);
                    end
                    begin
                        send_weight_tile(n_idx, k_idx);
                    end
                join

                ckpt_a(n_idx, k_idx, "AFTER_START");

                count_activity(n_idx, k_idx);
                wait_for_done();
                ckpt_a(n_idx, k_idx, "AFTER_DONE");

                check_acc_ckpt(n_idx, k_idx);

                if (output_en) begin
                    check_outbuf_mem(n_idx);
                    ckpt_outbuf_state(n_idx, 0);
                    check_output_stream(n_idx);
                    ckpt_outbuf_state(n_idx, 1);
                end
            end
        end

        if (err_cnt == 0) $display("\n=== SUCCESS: Full System Verified ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);

        $finish;
    end

endmodule
