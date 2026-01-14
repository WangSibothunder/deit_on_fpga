// -----------------------------------------------------------------------------
// 文件名: deit_core.v
// 描述: 加速器核心层 (Fix: Input Skew + Output Deskew)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "/Users/wangsibo/program/deit_on_fpga/src/params.vh"


module deit_core (
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
    output wire                         ctrl_input_stream_en
);

    // =========================================================================
    // 1. Controller Instance
    // =========================================================================
    wire ctrl_drain_en_unused;
    
    global_controller u_controller (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .ap_start               (ap_start),
        .cfg_k_dim              (cfg_compute_cycles),
        .ap_done                (ap_done),
        .ap_idle                (ap_idle),
        .current_state_dbg      (),
        .ctrl_weight_load_en    (ctrl_weight_load_en),
        .ctrl_input_stream_en   (ctrl_input_stream_en),
        .ctrl_drain_en          (ctrl_drain_en_unused)
    );

    // =========================================================================
    // 2. Input Logic: Row Load Enable Shift Register
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
    // 3. Input Logic: Input Skew Buffer (Rect -> Diamond)
    // =========================================================================
    // Row i 延迟 i 个周期
    wire [`ARRAY_ROW*`DATA_WIDTH-1:0] skewed_in_act_vec;

    genvar r;
    generate
        for (r = 0; r < `ARRAY_ROW; r = r + 1) begin : IN_SKEW
            if (r == 0) begin
                assign skewed_in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH] 
                     = in_act_vec[(r*`DATA_WIDTH) +: `DATA_WIDTH];
            end else begin
                // 移位寄存器链
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
    // 4. Systolic Array Instance
    // =========================================================================
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] array_raw_out;

    systolic_array u_array (
        .clk            (clk),
        .rst_n          (rst_n),
        .en_compute     (ctrl_input_stream_en), // Simplified enable
        .row_load_en    (row_load_en),
        .in_act_vec     (skewed_in_act_vec),
        .in_weight_vec  (in_weight_vec),
        .out_psum_vec   (array_raw_out)
    );

    // =========================================================================
    // 5. Output Logic: Output Deskew Buffer (Diamond -> Rect)
    // =========================================================================
    // 关键修复：我们要把菱形输出重新对齐。
    // Col 0 最早出来，Col 15 最晚出来。
    // Max Delay in Array = Row_Depth + Col_Width = 12 + 15 = 27 (relative to input start)
    // Col c arrives at: 12 + c
    // Delay needed for Col c: (Max_Delay) - (Arrival_Time) 
    //                       = (12 + 15) - (12 + c) 
    //                       = 15 - c
    
    wire [`ARRAY_COL*`ACC_WIDTH-1:0] aligned_out_vec;
    genvar c;
    
    generate
        for (c = 0; c < `ARRAY_COL; c = c + 1) begin : OUT_DESKEW
            localparam DELAY_NEEDED = (`ARRAY_COL - 1) - c;
            
            if (DELAY_NEEDED == 0) begin
                // Col 15 (最后一列) 不需要延迟
                assign aligned_out_vec[(c*`ACC_WIDTH) +: `ACC_WIDTH] 
                     = array_raw_out[(c*`ACC_WIDTH) +: `ACC_WIDTH];
            end else begin
                // Delay Chain for 32-bit Partial Sums
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
    // 6. Glue Logic: Latency Compensation
    // =========================================================================
    // 总延迟 = Input Skew (TB+Sample) + Array Depth + Output Deskew
    // TB Input Drive: 1 cycle (posedge to posedge sampling)
    // Row 0 Input Reg: 0 cycle (direct assign in skew logic if r=0? No, let's trace)
    // Actually simpler:
    // Path for Col 15 (Critical Path):
    // TB Drive (1) + Input Skew (0 for Row 0) + Horizontal (15) + Vertical (12) + Deskew (0) = 28?
    // Let's use the constant we derived: Max Latency relative to input_en = 12 + 15 = 27.
    // Plus 1 for TB driving delay.
    // Plus maybe 1 for safety/registering.
    // Let's try 29 (12 + 15 + 2).
    
    localparam LATENCY = `ARRAY_ROW + `ARRAY_COL + 1; // 12 + 16 + 1 = 29 (Conservative)
    
    reg [LATENCY-1:0] valid_delay_line;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) valid_delay_line <= 0;
        else valid_delay_line <= {valid_delay_line[LATENCY-2:0], ctrl_input_stream_en};
    end

    wire acc_wr_en = valid_delay_line[LATENCY-1]; 

    // =========================================================================
    // 7. Address Gen & Accumulator
    // =========================================================================
    reg [3:0] acc_addr;
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

    accumulator_bank u_accum (
        .clk            (clk),
        .rst_n          (rst_n),
        .addr           (acc_addr),
        .wr_en          (acc_wr_en),
        .acc_mode       (cfg_acc_mode),
        .in_psum_vec    (aligned_out_vec), // Connected to ALIGNED signals
        .out_acc_vec    (out_acc_vec)
    );

endmodule