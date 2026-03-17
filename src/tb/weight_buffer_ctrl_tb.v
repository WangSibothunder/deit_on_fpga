// -----------------------------------------------------------------------------
// File: src/tb/weight_buffer_ctrl_tb.v
// Desc: Verify 24-beat write + 12-row read order
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module weight_buffer_ctrl_tb;

    reg clk, rst_n;
    reg [63:0] s_axis_tdata;
    reg s_axis_tvalid;
    wire s_axis_tready;

    reg i_weight_load_en;
    wire [127:0] o_weight_vec; // 16 * 8 = 128
    reg i_bank_swap;
    wire o_dat_valid;

    wire [3:0] dbg_wbuf_wr_ptr;
    wire dbg_wbuf_ram_wen;
    wire dbg_wbuf_gb_cnt;

    // DUT
    weight_buffer_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .i_weight_load_en(i_weight_load_en), .o_weight_vec(o_weight_vec),
        .o_dat_valid(o_dat_valid),
        .i_bank_swap(i_bank_swap),
        .dbg_wbuf_wr_ptr(dbg_wbuf_wr_ptr),
        .dbg_wbuf_ram_wen(dbg_wbuf_ram_wen),
        .dbg_wbuf_gb_cnt(dbg_wbuf_gb_cnt)
    );

    always #5 clk = ~clk;

    task send_word;
        input [63:0] data;
        begin
            s_axis_tdata <= data;
            s_axis_tvalid <= 1;
            @(posedge clk);
            s_axis_tvalid <= 0;
        end
    endtask

    integer err_cnt = 0;
    integer i;
    integer row_idx;

    reg [63:0] beat_data [0:23];
    reg [127:0] exp_row [0:11];

    initial begin
        $dumpfile("weight_verify.vcd");
        $dumpvars(0, weight_buffer_ctrl_tb);

        clk = 0; rst_n = 0;
        s_axis_tdata = 0; s_axis_tvalid = 0;
        i_weight_load_en = 0; i_bank_swap = 0;

        // prepare expected data
        for (i = 0; i < 24; i = i + 1) begin
            beat_data[i] = {32'hA5A50000 + i[31:0], 32'h5A5A0000 + i[31:0]};
        end
        for (i = 0; i < 12; i = i + 1) begin
            exp_row[i] = {beat_data[i*2+1], beat_data[i*2]};
        end

        #20 rst_n = 1;
        #20;

        $display("=== START WEIGHT BUFFER VERIFICATION (24 BEATS) ===");

        // Write 24 beats into bank 0
        for (i = 0; i < 24; i = i + 1) begin
            send_word(beat_data[i]);
        end

        // Bank swap to read written bank
        @(posedge clk); i_bank_swap = 1;
        @(posedge clk); i_bank_swap = 0;

        // Read 12 rows
        i_weight_load_en = 1;
        row_idx = 0;
        while (row_idx < 12) begin
            @(posedge clk);
            if (o_dat_valid) begin
                if (o_weight_vec !== exp_row[row_idx]) begin
                    $display("[FAIL] Row %0d exp=%h got=%h", row_idx, exp_row[row_idx], o_weight_vec);
                    err_cnt = err_cnt + 1;
                end else begin
                    $display("[PASS] Row %0d val=%h", row_idx, o_weight_vec);
                end
                row_idx = row_idx + 1;
            end
        end
        i_weight_load_en = 0;

        // Debug checks
        if (dbg_wbuf_wr_ptr !== 12) begin
            $display("[WARN] dbg_wbuf_wr_ptr=%0d (expected 12)", dbg_wbuf_wr_ptr);
        end

        if (err_cnt == 0) $display("\n=== SUCCESS: All Checkpoints Passed! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        $finish;
    end

endmodule
