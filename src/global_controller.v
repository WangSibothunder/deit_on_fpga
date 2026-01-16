// -----------------------------------------------------------------------------
// 文件名: src/global_controller.v
// 版本: 2.0 (Added DRAIN State for Pipeline Management)
// 作者: Google FPGA Architect Mentor
// 描述: 全局主控制器
//       - 支持 Weight Loading -> Streaming Computation -> Pipeline Draining
//       - 适配 Batch Mode (全序列流式处理)
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`include "params.vh"
module global_controller #(
    // Pipeline Latency: 必须与 deit_core 的 LATENCY_CFG 匹配
    // 默认 28, 但为了保险起见，或者更灵活，可以由外部参数覆盖
    parameter LATENCY = 28
)(
    input  wire         clk,
    input  wire         rst_n,

    // --- Control Interface (AXI-Lite) ---
    input  wire         ap_start,
    input  wire [31:0]  cfg_seq_len, // 原 cfg_k_dim, 现更名为 cfg_seq_len (M维度)
    
    output reg          ap_done,
    output reg          ap_idle,

    // --- Status Debug ---
    output wire [2:0]   current_state_dbg,

    // --- Core Control Signals ---
    output reg          ctrl_weight_load_en,  // To Weight Buffer & Array
    output reg          ctrl_input_stream_en, // To Input Buffer
    output reg          ctrl_drain_en         // (Optional) 指示排空状态
);

    // -------------------------------------------------------------------------
    // FSM State Definition
    // -------------------------------------------------------------------------
    localparam S_IDLE     = 3'd0;
    localparam S_LOAD_W   = 3'd1; // Load Weights (12 cycles min)
    localparam S_COMPUTE  = 3'd2; // Stream Inputs (cfg_seq_len cycles)
    localparam S_DRAIN    = 3'd3; // Drain Pipeline (LATENCY cycles)
    localparam S_DONE     = 3'd4; // Pulse ap_done

    reg [2:0] state, next_state;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    reg [31:0] cnt_load;
    reg [31:0] cnt_seq;
    reg [31:0] cnt_drain;

    // 12 rows to load, but let's give it 16 cycles for safety/alignment
    localparam LOAD_CYCLES = 24; 

    // -------------------------------------------------------------------------
    // State Register
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // Next State Logic
    // -------------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (ap_start) next_state = S_LOAD_W;
            end

            S_LOAD_W: begin
                // Load weight rows into array
                if (cnt_load >= LOAD_CYCLES - 1) 
                    next_state = S_COMPUTE;
            end

            S_COMPUTE: begin
                // Stream input vectors (M dimension)
                // If cfg_seq_len is 0 (invalid), jump to done or handle gracefully
                if (cnt_seq >= cfg_seq_len - 1) 
                    next_state = S_DRAIN;
            end

            S_DRAIN: begin
                // Wait for the last input to travel through the array & adder
                if (cnt_drain >= LATENCY - 1) 
                    next_state = S_DONE;
            end

            S_DONE: begin
                // Single cycle pulse
                next_state = S_IDLE;
            end
            
            default: next_state = S_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Output Logic & Counters
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_weight_load_en  <= 0;
            ctrl_input_stream_en <= 0;
            ctrl_drain_en        <= 0;
            ap_done              <= 0;
            ap_idle              <= 1;
            
            cnt_load  <= 0;
            cnt_seq   <= 0;
            cnt_drain <= 0;
        end else begin
            // Default Values
            ctrl_weight_load_en  <= 0;
            ctrl_input_stream_en <= 0;
            ctrl_drain_en        <= 0;
            ap_done              <= 0;
            ap_idle              <= 0; // Busy by default unless in IDLE

            // case (next_state) // Look ahead for cleaner outputs or use current state
            //     // Note: Using 'state' for output logic usually incurs 1 cycle delay 
            //     // vs state transition. For controllers, this is fine or preferred.
            //     // Let's use current 'state' logic inside the clocked block.
            // endcase

            // Re-implementing logic based on CURRENT state for robustness
            case (state)
                S_IDLE: begin
                    ap_idle   <= 1;
                    cnt_load  <= 0;
                    cnt_seq   <= 0;
                    cnt_drain <= 0;
                end

                S_LOAD_W: begin
                    ctrl_weight_load_en <= 1; // ACTIVE
                    cnt_load <= cnt_load + 1;
                end

                S_COMPUTE: begin
                    ctrl_input_stream_en <= 1; // ACTIVE: Input Buffer Reads
                    cnt_seq <= cnt_seq + 1;
                end

                S_DRAIN: begin
                    ctrl_drain_en <= 1; // Status indicator (optional)
                    // Input stream is OFF (ctrl_input_stream_en = 0)
                    // This stops new data from entering, effectively feeding '0's 
                    // if the core logic handles enable low correctly.
                    cnt_drain <= cnt_drain + 1;
                end

                S_DONE: begin
                    ap_done <= 1;
                end
            endcase
        end
    end

    assign current_state_dbg = state;

endmodule