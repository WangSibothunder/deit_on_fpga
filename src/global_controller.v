// 
// -----------------------------------------------------------------------------
// 版本: 3.0 (Fix: Two-Phase Weight Loading)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
module global_controller #(
    parameter LATENCY = 28
)(
    input  wire         clk,
    input  wire         rst_n,

    input  wire         ap_start,
    input  wire [31:0]  cfg_seq_len,
    
    output reg          ap_done,
    output reg          ap_idle,
    output wire [2:0]   current_state_dbg,

    // --- Core Control Signals (Split) ---
    output reg          ctrl_weight_dma_req,  // [NEW] Phase 1: Request DMA -> Buffer
    output reg          ctrl_weight_load_en,  // [MOD] Phase 2: Buffer -> Array
    output reg          ctrl_input_stream_en, 
    output reg          ctrl_drain_en
);

    localparam S_IDLE     = 3'd0;
    localparam S_LOAD_W   = 3'd1; 
    localparam S_COMPUTE  = 3'd2;
    localparam S_DRAIN    = 3'd3;
    localparam S_DONE     = 3'd4;

    reg [2:0] state, next_state;
    reg [31:0] cnt_load;
    reg [31:0] cnt_seq;
    reg [31:0] cnt_drain;

    // Phase 1 (24cyc) + Phase 2 (12cyc) = 36 cycles total
    localparam CNT_PHASE1_END = 24; 
    localparam CNT_LOAD_TOTAL = 36; 

    // State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // Next State Logic
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE:    if (ap_start) next_state = S_LOAD_W;
            S_LOAD_W:  if (cnt_load >= CNT_LOAD_TOTAL - 1) next_state = S_COMPUTE;
            S_COMPUTE: if (cnt_seq >= cfg_seq_len - 1) next_state = S_DRAIN;
            S_DRAIN:   if (cnt_drain >= LATENCY - 1) next_state = S_DONE;
            S_DONE:    next_state = S_IDLE;
            default:   next_state = S_IDLE;
        endcase
    end

    // Output Logic & Counters
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_weight_dma_req  <= 0;
            ctrl_weight_load_en  <= 0;
            ctrl_input_stream_en <= 0;
            ctrl_drain_en        <= 0;
            ap_done <= 0; ap_idle <= 1;
            cnt_load <= 0; cnt_seq <= 0; cnt_drain <= 0;
        end else begin
            // Defaults
            ctrl_weight_dma_req  <= 0;
            ctrl_weight_load_en  <= 0;
            ctrl_input_stream_en <= 0;
            ctrl_drain_en        <= 0;
            ap_done <= 0; ap_idle <= 0;

            case (state)
                S_IDLE: begin
                    ap_idle <= 1;
                    cnt_load <= 0; cnt_seq <= 0; cnt_drain <= 0;
                end
                S_LOAD_W: begin
                    cnt_load <= cnt_load + 1;
                    if (cnt_load < CNT_PHASE1_END) begin
                        // Phase 1: Fill Buffer
                        ctrl_weight_dma_req <= 1;
                    end else begin
                        // Phase 2: Load Array
                        ctrl_weight_load_en <= 1;
                    end
                end
                S_COMPUTE: begin
                    ctrl_input_stream_en <= 1;
                    cnt_seq <= cnt_seq + 1;
                end
                S_DRAIN: begin
                    ctrl_drain_en <= 1;
                    cnt_drain <= cnt_drain + 1;
                end
                S_DONE: ap_done <= 1;
            endcase
        end
    end
    assign current_state_dbg = state;
endmodule