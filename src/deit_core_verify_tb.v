`timescale 1ns / 1ps
`include "params.vh"

module deit_core_verify_tb;

    localparam CLK_PERIOD = 10;
    localparam TEST_DIR = "src/test_data/";
    localparam M_STEPS = 16;

    reg clk, rst_n, ap_start;
    reg [31:0] cfg_compute_cycles;
    reg cfg_acc_mode;
    wire ap_done, ap_idle;
    wire ctrl_weight_load_en, ctrl_input_stream_en;
    
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec;
    reg [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec;
    wire [`ARRAY_COL*`ACC_WIDTH-1:0]  out_acc_vec;

    // Debug Ports
    wire dbg_acc_wr_en;
    wire [3:0] dbg_acc_addr;
    wire [31:0] dbg_aligned_col0;
    wire [31:0] dbg_aligned_col15;

    // Memories
    reg [`ARRAY_COL*`DATA_WIDTH-1:0] mem_w_t1 [0:11];
    reg [`ARRAY_COL*`DATA_WIDTH-1:0] mem_w_t2 [0:11];
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0] mem_in_t1 [0:15];
    reg [`ARRAY_ROW*`DATA_WIDTH-1:0] mem_in_t2 [0:15];
    reg [`ARRAY_COL*`ACC_WIDTH-1:0]  mem_golden [0:15];

    // DUT Instantiation with LATENCY override
    // 如果仿真失败，我们可以只改这里，不用改 RTL
    deit_core #(
        .LATENCY_CFG(28) // 初始尝试 31
    ) dut (
        .clk(clk), .rst_n(rst_n), .ap_start(ap_start),
        .cfg_compute_cycles(cfg_compute_cycles), .cfg_acc_mode(cfg_acc_mode),
        .ap_done(ap_done), .ap_idle(ap_idle),
        .in_act_vec(in_act_vec), .in_weight_vec(in_weight_vec), .out_acc_vec(out_acc_vec),
        .ctrl_weight_load_en(ctrl_weight_load_en), .ctrl_input_stream_en(ctrl_input_stream_en),
        // Debug
        .dbg_acc_wr_en(dbg_acc_wr_en),
        .dbg_acc_addr(dbg_acc_addr),
        .dbg_aligned_col0(dbg_aligned_col0),
        .dbg_aligned_col15(dbg_aligned_col15)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    integer w_ptr, in_ptr, tile_idx;

    initial begin
        $dumpfile("core_verify.vcd");
        $dumpvars(0, deit_core_verify_tb);
        
        // Load files
        $readmemh({TEST_DIR, "weights_t1.mem"}, mem_w_t1);
        $readmemh({TEST_DIR, "inputs_t1.mem"}, mem_in_t1);
        $readmemh({TEST_DIR, "weights_t2.mem"}, mem_w_t2);
        $readmemh({TEST_DIR, "inputs_t2.mem"}, mem_in_t2);
        $readmemh({TEST_DIR, "golden_c.mem"}, mem_golden);

        clk=0; rst_n=0; ap_start=0; tile_idx=0; cfg_compute_cycles=M_STEPS;
        #100 rst_n=1;

        // Tile 1
        $display("[TB] Starting Tile 1...");
        tile_idx=1; cfg_acc_mode=0; w_ptr=0; in_ptr=0;
        @(posedge clk); ap_start=1; @(posedge clk); ap_start=0;
        wait(ap_done);
        $display("[TB] Tile 1 Done.");
        #200;

        // Tile 2
        $display("[TB] Starting Tile 2...");
        tile_idx=2; cfg_acc_mode=1; w_ptr=0; in_ptr=0;
        @(posedge clk); ap_start=1; @(posedge clk); ap_start=0;
        wait(ap_done);
        $display("[TB] Tile 2 Done.");
        
        #200;
        check_results();
        $finish;
    end

    // Data Feeder
    always @(posedge clk) begin
        if (ctrl_weight_load_en) begin
            if (tile_idx==1) in_weight_vec <= mem_w_t1[w_ptr];
            else in_weight_vec <= mem_w_t2[w_ptr];
            if (w_ptr < 11) w_ptr <= w_ptr+1;
        end else w_ptr <= 0;

        if (ctrl_input_stream_en) begin
            if (tile_idx==1) in_act_vec <= mem_in_t1[in_ptr];
            else in_act_vec <= mem_in_t2[in_ptr];
            if (in_ptr < 15) in_ptr <= in_ptr+1;
        end else begin
            in_act_vec <= 0; in_ptr <= 0;
        end
    end

    // Result Checker
    task check_results;
        integer m, c, errors;
        reg signed [31:0] val_dut, val_gold;
        begin
            errors = 0;
            $display("[TB] Checking results...");
            for (m=0; m<M_STEPS; m=m+1) begin
                force dut.acc_addr = m;
                #1; 
                for (c=0; c<16; c=c+1) begin
                    val_dut = dut.out_acc_vec[c*32 +: 32];
                    val_gold = mem_golden[m][c*32 +: 32];
                    if (val_dut !== val_gold) begin
                        $display("[FAIL] Row %0d Col %0d: Exp %d, Got %d", m, c, val_gold, val_dut);
                        errors = errors + 1;
                    end else begin
                        $display("[PASS] Row %0d Col %0d: Exp %d, Got %d", m, c, val_gold, val_dut);
                    end
                end
                release dut.acc_addr;
            end
            if (errors == 0) $display("\n[SUCCESS] All matched!\n");
            else $display("\n[FAIL] %0d mismatches.\n", errors);
        end
    endtask
endmodule