// -----------------------------------------------------------------------------
// File: src/tb/deit_core_sanity_tb.v
// Desc: Sanity test for core + buffers (all-ones data)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module deit_core_sanity_tb;

    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_seq_len;
    reg cfg_acc_mode;

    wire ap_done, ap_idle;
    wire ctrl_weight_dma_req;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;

    // Input buffer stream
    reg  [63:0] s_axis_in_tdata;
    reg         s_axis_in_tvalid;
    reg         s_axis_in_tlast;

    // Weight buffer stream
    reg  [63:0] s_axis_w_tdata;
    reg         s_axis_w_tvalid;

    // Buffer outputs
    wire [`ARRAY_ROW*8-1:0] ibuf_to_core;
    wire [`ARRAY_COL*8-1:0] wbuf_to_core;
    wire ibuf_valid;
    wire wbuf_valid;

    // Bank swap pulses
    reg ibuf_bank_swap;
    reg wbuf_bank_swap;

    // Core output
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] out_acc_vec;

    integer wval_cnt;
    integer ival_cnt;
    integer wval_err;
    integer ival_err;
    reg [`ARRAY_ROW-1:0] row_load_mask;
    integer row_load_cnt;

    // DUTs
    input_buffer_ctrl u_ibuf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_in_tdata),
        .s_axis_tvalid(s_axis_in_tvalid),
        .s_axis_tready(),
        .s_axis_tlast(s_axis_in_tlast),
        .i_rd_en(ctrl_input_stream_en),
        .o_array_vec(ibuf_to_core),
        .o_dat_valid(ibuf_valid),
        .i_bank_swap(ibuf_bank_swap),
        .dbg_ibuf_wr_ptr()
    );

    weight_buffer_ctrl u_wbuf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_w_tdata),
        .s_axis_tvalid(s_axis_w_tvalid),
        .s_axis_tready(),
        .i_weight_load_en(ctrl_weight_load_en),
        .o_weight_vec(wbuf_to_core),
        .o_dat_valid(wbuf_valid),
        .i_bank_swap(wbuf_bank_swap),
        .dbg_wbuf_wr_ptr(),
        .dbg_wbuf_ram_wen(),
        .dbg_wbuf_gb_cnt()
    );

    deit_core #(
        .LATENCY_CFG(27),
        .ADDR_WIDTH(8)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .ap_start(ap_start),
        .cfg_compute_cycles(cfg_seq_len),
        .cfg_acc_mode(cfg_acc_mode),
        .ap_done(ap_done),
        .ap_idle(ap_idle),
        .in_act_vec(ibuf_to_core),
        .in_weight_vec(wbuf_to_core),
        .i_weight_valid(wbuf_valid),
        .i_weight_dma_beat(s_axis_w_tvalid),
        .i_input_valid(ibuf_valid),
        .i_dbg_clr(1'b0),
        .out_acc_vec(out_acc_vec),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_weight_dma_req(ctrl_weight_dma_req),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .dbg_acc_wr_en(), .dbg_acc_addr(), .dbg_aligned_col0(), .dbg_aligned_col15(), .dbg_raw_col0(),
        .dbg_ctrl_state(), .dbg_cnt_load(), .dbg_cnt_seq(), .dbg_cnt_drain(), .dbg_weight_beat_cnt()
    );

    // Clock
    always #5 clk = ~clk;

    // Monitor buffer outputs
    always @(posedge clk) begin
        if (!rst_n) begin
            wval_cnt <= 0;
            ival_cnt <= 0;
            wval_err <= 0;
            ival_err <= 0;
            row_load_mask <= 0;
            row_load_cnt <= 0;
        end else begin
            if (ctrl_weight_load_en && wbuf_valid) begin
                wval_cnt <= wval_cnt + 1;
                if (wval_cnt < 4) begin
                    $display("[DBG] wload cycle %0d row_load_en=0x%0h wbuf=0x%0h", wval_cnt, u_core.row_load_en, wbuf_to_core);
                end
                if (wbuf_to_core !== {16{8'h01}}) begin
                    wval_err <= wval_err + 1;
                end
            end
            if (ctrl_input_stream_en && ibuf_valid) begin
                ival_cnt <= ival_cnt + 1;
                if (ibuf_to_core !== {12{8'h01}}) begin
                    ival_err <= ival_err + 1;
                end
            end
            if (u_core.row_load_en != 0) begin
                row_load_mask <= row_load_mask | u_core.row_load_en;
                row_load_cnt <= row_load_cnt + 1;
            end
        end
    end

    task send_in_word;
        input [63:0] data;
        begin
            s_axis_in_tdata <= data;
            s_axis_in_tvalid <= 1;
            @(posedge clk);
            s_axis_in_tvalid <= 0;
        end
    endtask

    task send_w_word;
        input [63:0] data;
        begin
            s_axis_w_tdata <= data;
            s_axis_w_tvalid <= 1;
            @(posedge clk);
            s_axis_w_tvalid <= 0;
        end
    endtask

    integer i;
    reg [31:0] acc0;

    initial begin
        $dumpfile("core_sanity.vcd");
        $dumpvars(0, deit_core_sanity_tb);

        clk = 0; rst_n = 0;
        ap_start = 0; cfg_seq_len = 2; cfg_acc_mode = 0;
        s_axis_in_tdata = 0; s_axis_in_tvalid = 0; s_axis_in_tlast = 0;
        s_axis_w_tdata = 0; s_axis_w_tvalid = 0;
        ibuf_bank_swap = 0; wbuf_bank_swap = 0;
        wval_cnt = 0; ival_cnt = 0; wval_err = 0; ival_err = 0; row_load_mask = 0; row_load_cnt = 0;

        #20 rst_n = 1;
        #20;

        // Preload input: 2 vectors of 12 ones => 3 words of 0x01
        for (i = 0; i < 3; i = i + 1) begin
            send_in_word(64'h0101010101010101);
        end

        // Start core (this triggers DMA req)
        @(posedge clk);
        ap_start <= 1;
        // Input bank swap on start
        ibuf_bank_swap <= 1;
        @(posedge clk);
        ap_start <= 0;
        ibuf_bank_swap <= 0;

        // Wait DMA request and send 24 beats of weight (all ones)
        wait(ctrl_weight_dma_req == 1);
        for (i = 0; i < 24; i = i + 1) begin
            send_w_word(64'h0101010101010101);
        end

        // Bank swap weight after DMA req deassert
        wait(ctrl_weight_dma_req == 0);
        @(posedge clk);
        wbuf_bank_swap <= 1;
        @(posedge clk);
        wbuf_bank_swap <= 0;

        // Wait done
        wait(ap_done == 1);
        @(posedge clk);

        // Check accumulator col0 row0, row1
        acc0 = u_core.u_accum.COL_BANK[0].u_bank.mem[0];
        if (acc0 !== 32'd12) begin
            $display("[FAIL] Row0 col0=%0d (expected 12)", acc0);
        end else begin
            $display("[PASS] Row0 col0=%0d", acc0);
        end
        acc0 = u_core.u_accum.COL_BANK[0].u_bank.mem[1];
        if (acc0 !== 32'd12) begin
            $display("[FAIL] Row1 col0=%0d (expected 12)", acc0);
        end else begin
            $display("[PASS] Row1 col0=%0d", acc0);
        end

        $display("[INFO] wbuf_valid_cnt=%0d wbuf_err=%0d", wval_cnt, wval_err);
        $display("[INFO] ibuf_valid_cnt=%0d ibuf_err=%0d", ival_cnt, ival_err);
        $display("[INFO] row_load_mask=0x%0h", row_load_mask);
        $display("[INFO] row_load_cnt=%0d", row_load_cnt);

        $finish;
    end

endmodule
