// -----------------------------------------------------------------------------
// 文件名: src/deit_core.v
// 版本: 1.2 (Address Width Expansion)
// 描述: 核心计算逻辑，已升级累加器地址位宽至 8-bit (支持 M=197)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"

module deit_core #(
    parameter LATENCY_CFG = 28,
    parameter ADDR_WIDTH  = 8 // NEW: Address Width Parameter
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Control ---
    input  wire                         ap_start,
    input  wire [31:0]                  cfg_compute_cycles,
    input  wire                         cfg_acc_mode,
    output wire                         ap_done,
    output wire                         ap_idle,

    // --- Data Streams ---
    input  wire [`ARRAY_ROW*`DATA_WIDTH-1:0]  in_act_vec,
    input  wire [`ARRAY_COL*`DATA_WIDTH-1:0]  in_weight_vec,
    output wire [`ARRAY_COL*`ACC_WIDTH-1:0]   out_acc_vec,
    
    // --- Buffer Controls ---
    output wire                         ctrl_weight_load_en,
    output wire                         ctrl_input_stream_en,

    // --- DEBUG PORTS (Updated Width) ---
    output wire                         dbg_acc_wr_en,
    output wire [ADDR_WIDTH-1:0]        dbg_acc_addr, // Expanded
    output wire [`ACC_WIDTH-1:0]        dbg_aligned_col0,
    output wire [`ACC_WIDTH-1:0]        dbg_aligned_col15,
    output wire [`ACC_WIDTH-1:0]        dbg_raw_col0
);

    // =========================================================================
    // 1. Controller
    // =========================================================================
    wire ctrl_drain_en_unused;
    
    global_controller #(
        .LATENCY(LATENCY_CFG)
    ) u_controller (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .ap_start               (ap_start),
        .cfg_seq_len            (cfg_compute_cycles),
        .ap_done                (ap_done),
        .ap_idle                (ap_idle),
        .current_state_dbg      (),
        .ctrl_weight_load_en    (ctrl_weight_load_en),
        .ctrl_input_stream_en   (ctrl_input_stream_en),
        .ctrl_drain_en          (ctrl_drain_en_unused)
    );

    // =========================================================================
    // 2. Input Row Load Logic
    // =========================================================================
    reg [`ARRAY_ROW-1:0] row_load_en;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) row_load_en <= 0;
        else begin
            if (ctrl_weight_load_en) begin
                if (row_load_en == 0) row_load_en <= 1;
                else row_load_en <= (row_load_en << 1);
            end else begin
                row_load_en <= 0;
            end
        end
    end

    // =========================================================================
    // 3. Input Skew
    // =========================================================================
    wire [`ARRAY_ROW*`DATA_WIDTH-1:0] skewed_in_act_vec;
    genvar r;
    generate
        for (r = 0; r < `ARRAY_ROW; r = r + 1) begin : IN_SKEW
            if (r == 0) begin
                assign skewed_in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH] 
                     = in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH];
            end else begin
                reg [(r*`DATA_WIDTH)-1:0] delay_chain;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) delay_chain <= 0;
                    else begin
                        if (r == 1) delay_chain <= in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH];
                        else delay_chain <= {delay_chain[((r-1)*`DATA_WIDTH)-1:0], in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH]};
                    end
                end
                assign skewed_in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH] 
                     = delay_chain[(r*`DATA_WIDTH)-1 -: `DATA_WIDTH];
            end
        end
    endgenerate

    // =========================================================================
    // 4. Systolic Array
    // =========================================================================
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] array_raw_out;
    wire safe_compute_en = 1'b1; 

    systolic_array u_array (
        .clk            (clk),
        .rst_n          (rst_n),
        .en_compute     (safe_compute_en), 
        .row_load_en    (row_load_en),
        .in_act_vec     (skewed_in_act_vec),
        .in_weight_vec  (in_weight_vec),
        .out_psum_vec   (array_raw_out)
    );

    // =========================================================================
    // 5. Output Deskew
    // =========================================================================
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] aligned_out_vec;
    genvar c;
    generate
        for (c = 0; c < `ARRAY_COL; c = c + 1) begin : OUT_DESKEW
            localparam DELAY_NEEDED = (`ARRAY_COL - 1) - c;
            
            if (DELAY_NEEDED == 0) begin
                assign aligned_out_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH] 
                     = array_raw_out[(c*`ACC_WIDTH) +: `ACC_WIDTH];
            end else begin
                reg [(DELAY_NEEDED*`ACC_WIDTH)-1:0] out_delay_chain;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) out_delay_chain <= 0;
                    else begin
                        if (DELAY_NEEDED == 1) 
                            out_delay_chain <= array_raw_out[(c*`ACC_WIDTH) +: `ACC_WIDTH];
                        else 
                            out_delay_chain <= {out_delay_chain[((DELAY_NEEDED-1)*`ACC_WIDTH)-1:0], array_raw_out[(c*`ACC_WIDTH) +: `ACC_WIDTH]};
                    end
                end
                assign aligned_out_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH] 
                     = out_delay_chain[(DELAY_NEEDED*`ACC_WIDTH)-1 -: `ACC_WIDTH];
            end
        end
    endgenerate

    // =========================================================================
    // 6. Latency Compensation (Valid Line)
    // =========================================================================
    reg [LATENCY_CFG-1:0] valid_delay_line;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_delay_line <= 0;
        else valid_delay_line <= {valid_delay_line[LATENCY_CFG-2:0], ctrl_input_stream_en};
    end
    wire acc_wr_en = valid_delay_line[LATENCY_CFG-1]; 

    // =========================================================================
    // 7. Accumulator Bank Control (UPDATED)
    // =========================================================================
    // Change reg width from 3:0 to ADDR_WIDTH-1:0
    reg [ADDR_WIDTH-1:0] acc_addr; 
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_addr <= 0;
        end else begin
            if (acc_wr_en) begin
                acc_addr <= acc_addr + 1;
            end else if (ap_idle) begin
                acc_addr <= 0; 
            end
        end
    end

    accumulator_bank #(
        .ADDR_WIDTH(ADDR_WIDTH) // Pass parameter
    ) u_accum (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (acc_addr),
        .wr_en          (acc_wr_en),
        .acc_mode       (cfg_acc_mode),
        .in_psum_vec    (aligned_out_vec),
        .out_acc_vec    (out_acc_vec)
    );

    // =========================================================================
    // 8. Debug Signals
    // =========================================================================
    assign dbg_acc_wr_en     = acc_wr_en;
    assign dbg_acc_addr      = acc_addr;
    assign dbg_aligned_col0  = aligned_out_vec[0 +: `ACC_WIDTH];
    assign dbg_aligned_col15 = aligned_out_vec[(`ARRAY_COL-1)*`ACC_WIDTH +: `ACC_WIDTH];
    assign dbg_raw_col0      = array_raw_out[0 +: `ACC_WIDTH];

endmodule