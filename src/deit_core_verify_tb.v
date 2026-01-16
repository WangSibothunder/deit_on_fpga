// -----------------------------------------------------------------------------
// 文件名: src/deit_core_verify_tb.v
// 描述: DeiT Core 核心功能验证 (32x12 x 12x16)
//       - 使用 Python 生成的真实矩阵数据
//       - 检查流水线时序和数值正确性
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "params.vh"

module deit_core_verify_tb;

    // --- Configuration ---
    localparam M_DIM = 32;
    localparam K_DIM = 12; // Physical limit for single pass
    localparam N_DIM = 16; // Physical limit
    localparam LATENCY = 28;

    // --- Signals ---
    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_compute_cycles;
    reg cfg_acc_mode;
    wire ap_done;
    wire ap_idle;

    // Data Interfaces
    reg [`ARRAY_ROW*8-1:0] mem_input_data [0:1023];  // Input Buffer Mimic
    reg [`ARRAY_COL*8-1:0] mem_weight_data [0:15];   // Weight Buffer Mimic
    reg [`ARRAY_COL*32-1:0] mem_golden_data [0:1023]; // Golden Results

    reg [`ARRAY_ROW*8-1:0] in_act_vec;
    reg [`ARRAY_COL*8-1:0] in_weight_vec;
    wire [`ARRAY_COL*32-1:0] out_acc_vec;

    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;

    // Debug Ports
    wire dbg_acc_wr_en;
    wire [7:0] dbg_acc_addr;

    // --- DUT ---
    deit_core #(
        .LATENCY_CFG(LATENCY),
        .ADDR_WIDTH(8)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .ap_start(ap_start),
        .cfg_compute_cycles(cfg_compute_cycles),
        .cfg_acc_mode(cfg_acc_mode),
        .ap_done(ap_done), .ap_idle(ap_idle),
        .in_act_vec(in_act_vec),
        .in_weight_vec(in_weight_vec),
        .out_acc_vec(out_acc_vec),
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en),
        .dbg_acc_wr_en(dbg_acc_wr_en),
        .dbg_acc_addr(dbg_acc_addr)
        // .dbg_* (ignored)
    );

    always #5 clk = ~clk;

    // --- Buffer Simulation Logic ---
    integer w_ptr, i_ptr;

    // Weight Feeder
    always @(posedge clk) begin
        if (ctrl_weight_load_en) begin
            in_weight_vec <= mem_weight_data[w_ptr];
            w_ptr <= w_ptr + 1;
        end else begin
            w_ptr <= 0;
            in_weight_vec <= 0;
        end
    end

    // Input Feeder
    always @(posedge clk) begin
        if (ctrl_input_stream_en) begin
            in_act_vec <= mem_input_data[i_ptr];
            i_ptr <= i_ptr + 1;
        end else begin
            i_ptr <= 0;
            in_act_vec <= 0;
        end
    end

    // --- Verification Flow ---
    integer i, col;
    integer err_cnt = 0;
    
    // Helper to get golden pixel
    function signed [31:0] get_golden_pixel;
        input integer row_idx;
        input integer col_idx;
        begin
            get_golden_pixel = mem_golden_data[row_idx][(col_idx*32) +: 32];
        end
    endfunction

    // Helper to peek DUT memory (Hierarchical Access)
    function signed [31:0] peek_dut_acc;
        input integer row_idx;
        input integer col_idx;
        begin
            case (col_idx)
                // 注意: generate block 的命名取决于编译器。
                // 在 iverilog 中，具名 generate block (COL_BANK) 会保留名字。
                // 路径通常是: dut.u_accum.COL_BANK[i].u_bank.mem[row]
                
                0: peek_dut_acc = dut.u_accum.COL_BANK[0].u_bank.mem[row_idx];
                1: peek_dut_acc = dut.u_accum.COL_BANK[1].u_bank.mem[row_idx];
                2: peek_dut_acc = dut.u_accum.COL_BANK[2].u_bank.mem[row_idx];
                3: peek_dut_acc = dut.u_accum.COL_BANK[3].u_bank.mem[row_idx];
                4: peek_dut_acc = dut.u_accum.COL_BANK[4].u_bank.mem[row_idx];
                5: peek_dut_acc = dut.u_accum.COL_BANK[5].u_bank.mem[row_idx];
                6: peek_dut_acc = dut.u_accum.COL_BANK[6].u_bank.mem[row_idx];
                7: peek_dut_acc = dut.u_accum.COL_BANK[7].u_bank.mem[row_idx];
                8: peek_dut_acc = dut.u_accum.COL_BANK[8].u_bank.mem[row_idx];
                9: peek_dut_acc = dut.u_accum.COL_BANK[9].u_bank.mem[row_idx];
                10: peek_dut_acc = dut.u_accum.COL_BANK[10].u_bank.mem[row_idx];
                11: peek_dut_acc = dut.u_accum.COL_BANK[11].u_bank.mem[row_idx];
                12: peek_dut_acc = dut.u_accum.COL_BANK[12].u_bank.mem[row_idx];
                13: peek_dut_acc = dut.u_accum.COL_BANK[13].u_bank.mem[row_idx];
                14: peek_dut_acc = dut.u_accum.COL_BANK[14].u_bank.mem[row_idx];
                15: peek_dut_acc = dut.u_accum.COL_BANK[15].u_bank.mem[row_idx];
                default: peek_dut_acc = 32'hDEADBEEF;
            endcase
        end
    endfunction

    initial begin
        $dumpfile("core_verify.vcd");
        $dumpvars(0, deit_core_verify_tb);

        // 1. Load Data
        $readmemh("src/test_data_core/core_input.mem", mem_input_data);
        $readmemh("src/test_data_core/core_weight.mem", mem_weight_data);
        $readmemh("src/test_data_core/core_golden.mem", mem_golden_data);

        // 2. Init
        clk = 0; rst_n = 0; ap_start = 0; 
        cfg_compute_cycles = M_DIM; 
        cfg_acc_mode = 0; // Overwrite
        w_ptr = 0; i_ptr = 0;

        #20 rst_n = 1;
        #20;

        $display("=== START DEIT CORE COMPLEX VERIFICATION ===");
        $display("Matrix Size: %0dx%0d * %0dx%0d", M_DIM, K_DIM, K_DIM, N_DIM);

        // 3. Trigger Start
        @(posedge clk);
        ap_start = 1;
        @(posedge clk);
        ap_start = 0;

        // 4. Wait for Done
        // Timeout protection
        fork : wait_done
            begin
                wait(ap_done);
                $display("[INFO] Core finished computing.");
                disable wait_done;
            end
            begin
                #50000;
                $display("[FAIL] Timeout waiting for ap_done!");
                $finish;
            end
        join

        // 5. Verify Results (Backdoor Read)
        $display("[INFO] Verifying Accumulator Memory Content...");
        
        // Wait for idle state logic to settle
        #50;

        for (i = 0; i < M_DIM; i = i + 1) begin
            for (col = 0; col < 16; col = col + 1) begin
                if (peek_dut_acc(i, col) !== get_golden_pixel(i, col)) begin
                    $display("[FAIL] Mismatch at Row %0d, Col %0d", i, col);
                    $display("       Exp: %d", get_golden_pixel(i, col));
                    $display("       Got: %d", peek_dut_acc(i, col));
                    err_cnt = err_cnt + 1;
                    
                    // Stop after some errors to avoid log spam
                    if (err_cnt > 10) begin 
                        $display("[ABORT] Too many errors."); 
                        $finish; 
                    end
                end
            end
        end

        if (err_cnt == 0) begin
            $display("\n=== SUCCESS: Core Logic Perfect Match! ===\n");
        end else begin
            $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        end
        $finish;
    end

endmodule