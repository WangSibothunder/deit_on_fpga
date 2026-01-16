`timescale 1ns / 1ps
`include "params.vh"

module deit_core_verify_tb;

    // --- Simulation Parameters ---
    parameter CLK_PERIOD  = 10.0;
    parameter LATENCY_CFG = 28; 
    parameter M_FULL      = 36;
    parameter M_SPLIT     = 18; // Half batch
    parameter N_DIM       = 16; 
    
    // --- DUT Signals ---
    reg clk, rst_n;
    reg ap_start;
    reg [31:0] cfg_seq_len;
    reg cfg_acc_mode; // 0: Overwrite, 1: Accumulate
    
    wire ap_done, ap_idle;
    wire ctrl_weight_dma_req;
    wire ctrl_weight_load_en;
    wire ctrl_input_stream_en;
    
    // Data Stream Sim
    reg [63:0] s_axis_w_tdata;
    reg        s_axis_w_tvalid;
    
    reg [63:0] s_axis_in_tdata;
    reg        s_axis_in_tvalid;
    
    // Interconnects
    wire [`ARRAY_COL*8-1:0] wbuf_to_core;
    wire [`ARRAY_ROW*8-1:0] ibuf_to_core;
    wire [`ARRAY_COL*32-1:0] out_acc_vec;
    
    // --- Memory for Test Patterns (The 4+2 Files) ---
    reg [127:0] w_k0 [0:11];
    reg [127:0] w_k1 [0:11];
    
    reg [95:0]  a_m0_k0 [0:31]; // Max 32 lines per file
    reg [95:0]  a_m0_k1 [0:31];
    reg [95:0]  a_m1_k0 [0:31];
    reg [95:0]  a_m1_k1 [0:31];
    
    // Golden: M * 16 words of 32-bit
    reg [31:0]  golden_mem [0: M_FULL*N_DIM - 1];
    
    // --- Module Instantiation ---
    weight_buffer_ctrl u_wbuf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_w_tdata), .s_axis_tvalid(s_axis_w_tvalid),
        .i_weight_load_en(ctrl_weight_load_en), 
        .o_weight_vec(wbuf_to_core),
        .i_bank_swap(1'b0)
    );
    
    input_buffer_ctrl u_ibuf (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_in_tdata), .s_axis_tvalid(s_axis_in_tvalid),
        .i_rd_en(ctrl_input_stream_en),
        .o_array_vec(ibuf_to_core),
        .i_bank_swap(1'b0)
    );
    
    deit_core #(
        .LATENCY_CFG(LATENCY_CFG),
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
        .out_acc_vec(out_acc_vec),
        .ctrl_weight_dma_req(ctrl_weight_dma_req), 
        .ctrl_weight_load_en(ctrl_weight_load_en),
        .ctrl_input_stream_en(ctrl_input_stream_en)
    );
    
    always #(CLK_PERIOD/2) clk = ~clk;
    
    // --- Helpers ---
    task feed_weights(input integer part_id); // 0=k0, 1=k1
        integer r;
        reg [127:0] row_data;
        begin
            for (r=0; r<12; r=r+1) begin
                if (part_id == 0) row_data = w_k0[r];
                else              row_data = w_k1[r];
                
                @(posedge clk); s_axis_w_tvalid = 1; s_axis_w_tdata = row_data[63:0];
                @(posedge clk); s_axis_w_tvalid = 1; s_axis_w_tdata = row_data[127:64];
            end
            @(posedge clk); s_axis_w_tvalid = 0;
        end
    endtask
    
    task feed_inputs(input integer m_part, input integer k_part);
        integer m;
        reg [95:0] row_data;
        begin
            for (m=0; m<M_SPLIT; m=m+1) begin
                if      (m_part==0 && k_part==0) row_data = a_m0_k0[m];
                else if (m_part==0 && k_part==1) row_data = a_m0_k1[m];
                else if (m_part==1 && k_part==0) row_data = a_m1_k0[m];
                else                             row_data = a_m1_k1[m];
                
                @(posedge clk); s_axis_in_tvalid = 1; s_axis_in_tdata = row_data[63:0];
                @(posedge clk); s_axis_in_tvalid = 1; s_axis_in_tdata = {32'h0, row_data[95:64]};
            end
            @(posedge clk); s_axis_in_tvalid = 0;
        end
    endtask

    // --- Main Test ---
    integer err_cnt = 0;
    
    initial begin
        $dumpfile("core_verify.vcd");
        $dumpvars(0, deit_core_verify_tb);
        
        // Load Data
        $readmemh("src/test_data_core/w_k0.mem", w_k0);
        $readmemh("src/test_data_core/w_k1.mem", w_k1);
        $readmemh("src/test_data_core/a_m0_k0.mem", a_m0_k0);
        $readmemh("src/test_data_core/a_m0_k1.mem", a_m0_k1);
        $readmemh("src/test_data_core/a_m1_k0.mem", a_m1_k0);
        $readmemh("src/test_data_core/a_m1_k1.mem", a_m1_k1);
        $readmemh("src/test_data_core/golden.mem", golden_mem);
        
        // Init
        clk = 0; rst_n = 0; ap_start = 0; 
        s_axis_w_tvalid = 0; s_axis_in_tvalid = 0;
        cfg_seq_len = M_SPLIT; // 18
        
        #100 rst_n = 1; #20;

        // =====================================================================
        // BATCH 0: Compute Output Rows 0..17
        // =====================================================================
        $display("\n=== [Batch 0] Start: Rows 0-17 ===");

        // --- Step 1: Load W0, Run A_M0_K0 (Overwrite) ---
        $display("[CKPT] Step 1.1: Pre-fill A_M0_K0");
        feed_inputs(0, 0); 
        
        $display("[CKPT] Step 1.2: Start Core (Mode: Overwrite)");
        cfg_acc_mode = 0; 
        @(posedge clk); ap_start = 1; @(posedge clk); ap_start = 0;
        
        wait(ctrl_weight_dma_req == 1);
        feed_weights(0); // Load W0
        wait(ap_done);
        
        #50;
        
        // --- Step 2: Load W1, Run A_M0_K1 (Accumulate) ---
        $display("[CKPT] Step 2.1: Pre-fill A_M0_K1");
        feed_inputs(0, 1);
        
        $display("[CKPT] Step 2.2: Start Core (Mode: Accumulate)");
        cfg_acc_mode = 1;
        @(posedge clk); ap_start = 1; @(posedge clk); ap_start = 0;
        
        wait(ctrl_weight_dma_req == 1);
        feed_weights(1); // Load W1
        wait(ap_done);
        
        $display("[CKPT] Batch 0 Complete. Verifying Memory 0..17...");
        verify_memory(0); // Offset 0

        #100;

        // =====================================================================
        // BATCH 1: Compute Output Rows 18..35
        // =====================================================================
        $display("\n=== [Batch 1] Start: Rows 18-35 ===");

        // --- Step 3: Load W0, Run A_M1_K0 (Overwrite) ---
        // Note: Hardware Accumulator writes to address 0..17 again.
        // We verified 0..17 in previous step. Now we overwrite them.
        $display("[CKPT] Step 3.1: Pre-fill A_M1_K0");
        feed_inputs(1, 0);
        
        $display("[CKPT] Step 3.2: Start Core (Mode: Overwrite)");
        cfg_acc_mode = 0;
        @(posedge clk); ap_start = 1; @(posedge clk); ap_start = 0;
        
        wait(ctrl_weight_dma_req == 1);
        feed_weights(0); // Load W0
        wait(ap_done);
        
        #50;

        // --- Step 4: Load W1, Run A_M1_K1 (Accumulate) ---
        $display("[CKPT] Step 4.1: Pre-fill A_M1_K1");
        feed_inputs(1, 1);
        
        $display("[CKPT] Step 4.2: Start Core (Mode: Accumulate)");
        cfg_acc_mode = 1;
        @(posedge clk); ap_start = 1; @(posedge clk); ap_start = 0;
        
        wait(ctrl_weight_dma_req == 1);
        feed_weights(1); // Load W1
        wait(ap_done);
        
        $display("[CKPT] Batch 1 Complete. Verifying Memory 18..35...");
        // Note: From HW perspective, results are at 0..17. 
        // But we compare against Golden 18..35.
        verify_memory(18); 

        // =====================================================================
        // Final Result
        // =====================================================================
        if (err_cnt == 0) begin
            $display("\nSUCCESS: Blocked GEMM (2 Batch x 2 Tiles) Verified!");
            $display("PASS");
        end else begin
            $display("\nFAIL: Found %0d Errors.", err_cnt);
        end
        $finish;
    end
    
    // Verification Task
    // golden_offset: where in the Golden file we are comparing against.
    task verify_memory(input integer golden_offset);
        integer i, j;
        reg signed [31:0] g_val, d_val;
        begin
            for (i=0; i<M_SPLIT; i=i+1) begin
                for (j=0; j<N_DIM; j=j+1) begin
                    g_val = golden_mem[(golden_offset + i)*N_DIM + j];
                    
                    // Hardware always writes to 0..M_SPLIT-1
                    d_val = u_core.u_accum.gen_banks[j].u_bank.mem[i];
                    
                    if (g_val !== d_val) begin
                        $display("ERROR [Batch Offset %0d] Row %0d Col %0d: Exp %d Got %d", 
                                 golden_offset, i, j, g_val, d_val);
                        err_cnt = err_cnt + 1;
                    end
                end
            end
        end
    endtask

endmodule