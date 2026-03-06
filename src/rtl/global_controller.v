// -----------------------------------------------------------------------------
// 版本: 3.3 (Fix: Added Input Stream Handshake for Gearbox Latency)
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
    output reg          ctrl_weight_dma_req,  // Phase 1: Request DMA -> Buffer
    
    // Handshake Input: Buffer tells Controller when WEIGHT data is ready
    input  wire         i_weight_valid,       

    output reg          ctrl_weight_load_en,  // Phase 2: Buffer -> Array
    
    // [MOD] Input Control Signals
    // Handshake Input: Buffer tells Controller when INPUT data is ready
    input  wire         i_input_valid,        // [ADD] 新增端口

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

    // Phase 1 (27cyc) + Phase 2 (12cyc) = 39 cycles total
    // 注意：请确保这里的 CNT_PHASE1_END 足够覆盖你的 DMA 写入延迟
    localparam CNT_PHASE1_END = 27; 
    localparam CNT_LOAD_TOTAL = 39; 

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
            
            // [MOD] S_COMPUTE Transition
            // 只有当 cnt_seq (有效计算计数) 达到目标长度时才跳转
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
                    if (cnt_load < CNT_PHASE1_END) begin
                        // Phase 1: Fill Buffer (DMA)
                        ctrl_weight_dma_req <= 1;
                        cnt_load <= cnt_load + 1;
                    end else begin
                        // Phase 2: Load Array (Buffer -> Array)
                        ctrl_weight_load_en <= 1;
                        
                        // Handshake Mechanism (Weight):
                        if (i_weight_valid) begin
                            cnt_load <= cnt_load + 1;
                        end
                    end
                end
                
                S_COMPUTE: begin
                    // 1. 持续向 Input Buffer 发出读请求
                    // 即使数据还没准备好，我们也要一直请求，直到 Buffer 吐出数据
                    ctrl_input_stream_en <= 1;
                    
                    // 2. [FIX] Input Handshake Mechanism:
                    // 只有当 Input Buffer 说数据有效 (Gearbox 延迟已过) 时，
                    // 我们才推进 Sequence Counter。
                    if (i_input_valid) begin
                        cnt_seq <= cnt_seq + 1;
                    end
                    // 否则 cnt_seq 暂停 (Freeze)，防止 Core 吃进无效数据
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