`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"
`timescale 1ns/1ps
module systolic_array_tb;

    // ------------------------------------------------------------
    // Parameters
    // ------------------------------------------------------------
    localparam integer CLK_PERIOD = 10;
    localparam integer EXPECT_OUTPUT_TIME_PS = 185_000; // 185ns

    // ------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------
    reg                               clk;
    reg                               rst_n;
    reg                               en_compute;
    reg  [`ARRAY_ROW-1:0]             row_load_en;
    reg  [`ARRAY_ROW*`DATA_WIDTH-1:0] in_act_vec;
    reg  [`ARRAY_COL*`DATA_WIDTH-1:0] in_weight_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0]  out_psum_vec;

    // ------------------------------------------------------------
    // Local variables for test logic
    // ------------------------------------------------------------
    reg found_output;

    // Variables for computation and checking
    integer sum_act;
    integer mismatches;
    reg [`ACC_WIDTH-1:0] expected_val;
    reg [`ACC_WIDTH-1:0] actual_val;
    reg [`DATA_WIDTH-1:0] weight_val;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    systolic_array dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .en_compute     (en_compute),
        .row_load_en    (row_load_en),
        .in_act_vec     (in_act_vec),
        .in_weight_vec  (in_weight_vec),
        .out_psum_vec   (out_psum_vec)
    );

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ------------------------------------------------------------
    // Waveform
    // ------------------------------------------------------------
    initial begin
        $dumpfile("systolic_array_check.vcd");
        $dumpvars(0, systolic_array_tb);
    end

    // ------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------
    integer r, c;
    integer k;
    initial begin
        // ========================================================
        // CP0: Reset
        // ========================================================
        rst_n          = 0;
        en_compute    = 0;
        row_load_en   = 0;
        in_act_vec    = 0;
        in_weight_vec = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;

        // ========================================================
        // CP1: Init weights (column-wise constant)
        // ========================================================
        for (c = 0; c < `ARRAY_COL; c = c + 1)
            in_weight_vec[c*`DATA_WIDTH +: `DATA_WIDTH] = c + 1;

        // ========================================================
        // CP2: Row-wise weight load
        // ========================================================
        for (r = 0; r < `ARRAY_ROW; r = r + 1) begin
            row_load_en = (1 << r);
            @(posedge clk);
        end
        row_load_en = 0;
        @(posedge clk);

        // ========================================================
        // CP3: Init activations
        // ========================================================
        for (r = 0; r < `ARRAY_ROW; r = r + 1)
            in_act_vec[r*`DATA_WIDTH +: `DATA_WIDTH] = r + 1;

        // ========================================================
        // CP4: Enable compute
        // ========================================================
        en_compute = 1;

        // ========================================================
        // CP5: TIMING CHECKPOINT @ 185ns
        // ========================================================
        #(EXPECT_OUTPUT_TIME_PS);

        begin
            // --- detect any non-zero output first (as before) ---
            found_output = 0;
            for (k = 0; k < `ARRAY_COL; k = k + 1) begin
                if (out_psum_vec[k*`ACC_WIDTH +: `ACC_WIDTH] != 0)
                    found_output = 1;
            end

            if (!found_output) begin
                $display("\n[FAIL][CP_TIMING] No output at %0t ps (expected ~%0d ps)",
                         $time, EXPECT_OUTPUT_TIME_PS);
                $fatal;
            end else begin
                $display("\n[INFO] Output detected at %0t ps, now performing numeric checks...", $time);
            end

            // --- compute golden expected values ---
            sum_act = 0;
            for (r = 0; r < `ARRAY_ROW; r = r + 1) begin
                // extract activation for row r (unsigned)
                sum_act = sum_act + in_act_vec[r*`DATA_WIDTH +: `DATA_WIDTH];
            end

            // Prepare results
            mismatches = 0;

            // For printing hex/dec values

            for (c = 0; c < `ARRAY_COL; c = c + 1) begin
                weight_val = in_weight_vec[c*`DATA_WIDTH +: `DATA_WIDTH];
                // compute expected = weight * sum_act
                expected_val = weight_val * sum_act;
                actual_val   = out_psum_vec[c*`ACC_WIDTH +: `ACC_WIDTH];

                if (actual_val !== expected_val) begin
                    $display("[FAIL][NUM_CHECK] col=%0d  weight=%0d  sum_act=%0d  expected=0x%0h(%0d)  actual=0x%0h(%0d)",
                             c, weight_val, sum_act, expected_val, expected_val, actual_val, actual_val);
                    mismatches = mismatches + 1;
                end else begin
                    $display("[PASS][NUM_CHECK] col=%0d  weight=%0d  sum_act=%0d  value=0x%0h(%0d)",
                             c, weight_val, sum_act, expected_val, expected_val);
                end
            end

            if (mismatches == 0) begin
                $display("\n[PASS][CP_NUMERIC] All columns match expected values at %0t ps", $time);
            end else begin
                $display("\n[FAIL][CP_NUMERIC] %0d column(s) mismatched at %0t ps", mismatches, $time);
                $fatal;
            end
        end

        // ========================================================
        // CP6: Observe stability (extra cycles)
        // ========================================================
        repeat (10) @(posedge clk);

        $display("\n[TB] Simulation finished successfully");
        $finish;
    end

endmodule
