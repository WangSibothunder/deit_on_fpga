// -----------------------------------------------------------------------------
// 文件名: src/deit_accelerator_top_tb.v
// 描述: DeiT Accelerator 全系统验证 (Fixed Timing & Concurrency)
//       - Fix 1: 使用 fork-join 并行发送权重，解决 Controller 盲计数导致的窗口错生问题
//       - Fix 2: 增加 TLAST 驱动，确保 Buffer 指针复位
//       - Fix 3: 输入数据 (Input) 在 Start 之前预加载，避免 Compute 阶段无数据
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module deit_accelerator_top_tb;

    // --- 1. 参数与时钟 ---
    localparam C_S_AXI_DATA_WIDTH = 32;
    localparam C_S_AXI_ADDR_WIDTH = 6;
    
    // Matrix Dims
    localparam M_DIM = 32;
    localparam K_DIM = 24;
    localparam N_DIM = 32;

    reg clk, rst_n;
    always #5 clk = ~clk; // 100MHz

    // --- 2. 接口信号 ---
    // AXI-Lite
    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_awaddr;
    reg                            s_axi_awvalid;
    wire                           s_axi_awready;
    reg  [31:0]                    s_axi_wdata;
    reg  [3:0]                     s_axi_wstrb;
    reg                            s_axi_wvalid;
    wire                           s_axi_wready;
    wire [1:0]                     s_axi_bresp;
    wire                           s_axi_bvalid;
    reg                            s_axi_bready;
    
    reg  [C_S_AXI_ADDR_WIDTH-1:0]  s_axi_araddr;
    reg                            s_axi_arvalid;
    wire                           s_axi_arready;
    wire [31:0]                    s_axi_rdata;
    wire [1:0]                     s_axi_rresp;
    wire                           s_axi_rvalid;
    reg                            s_axi_rready;

    // AXI-Stream RX (DMA -> FPGA)
    reg  [63:0] axis_in_tdata;
    reg         axis_in_tvalid;
    wire        axis_in_tready;
    reg         axis_in_tlast;

    // AXI-Stream TX (FPGA -> DMA)
    wire [63:0] axis_out_tdata;
    wire        axis_out_tvalid;
    reg         axis_out_tready;
    wire        axis_out_tlast;

    // --- 3. DUT 实例化 ---
    deit_accelerator_top #(
        .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        // Lite
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        // Stream
        .axis_in_tdata(axis_in_tdata), .axis_in_tvalid(axis_in_tvalid), .axis_in_tready(axis_in_tready), .axis_in_tlast(axis_in_tlast),
        .axis_out_tdata(axis_out_tdata), .axis_out_tvalid(axis_out_tvalid), .axis_out_tready(axis_out_tready), .axis_out_tlast(axis_out_tlast)
    );

    // --- 4. 仿真文件内存 ---
    reg [63:0] file_input_k0 [0:255];
    reg [63:0] file_input_k1 [0:255];
    
    reg [63:0] file_weight_k0_n0 [0:31]; 
    reg [63:0] file_weight_k1_n0 [0:31];
    reg [63:0] file_weight_k0_n1 [0:31];
    reg [63:0] file_weight_k1_n1 [0:31];

    reg [63:0] file_golden_n0 [0:127]; 
    reg [63:0] file_golden_n1 [0:127];
    
    reg [31:0] file_config [0:3];

    initial begin
        // 使用相对路径
        // 注意：如果文件长度小于数组长度，Icarus 会报 Warning，这是正常的，只要有效数据部分被填满即可。
        $readmemh("src/test_data_top/axis_input_k0.mem", file_input_k0);
        $readmemh("src/test_data_top/axis_input_k1.mem", file_input_k1);
        
        $readmemh("src/test_data_top/axis_weight_k0_n0.mem", file_weight_k0_n0);
        $readmemh("src/test_data_top/axis_weight_k1_n0.mem", file_weight_k1_n0);
        $readmemh("src/test_data_top/axis_weight_k0_n1.mem", file_weight_k0_n1);
        $readmemh("src/test_data_top/axis_weight_k1_n1.mem", file_weight_k1_n1);
        
        $readmemh("src/test_data_top/axis_golden_n0.mem", file_golden_n0);
        $readmemh("src/test_data_top/axis_golden_n1.mem", file_golden_n1);
        
        $readmemh("src/test_data_top/config.mem", file_config);
    end

    // --- 5. AXI Helper Tasks ---
    
    task axi_lite_write;
        input [C_S_AXI_ADDR_WIDTH-1:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr <= addr; s_axi_awvalid <= 1;
            s_axi_wdata <= data; s_axi_wstrb <= 4'hF; s_axi_wvalid <= 1;
            s_axi_bready <= 1;
            wait(s_axi_awready && s_axi_wready);
            @(posedge clk);
            s_axi_awvalid <= 0; s_axi_wvalid <= 0;
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready <= 0;
        end
    endtask

    // DMA Send Task (With TLAST Fix)
    task send_stream_data;
        input [1:0] type_id; // 0: Weight, 1: Input
        input integer tile_id; 
        integer i;
        integer limit;
        begin
            if (type_id == 0) limit = 24; // Weight
            else              limit = 48; // Input

            for (i = 0; i < limit; i = i + 1) begin
                axis_in_tvalid <= 1;
                
                // Assert TLAST on the last beat
                if (i == limit - 1) axis_in_tlast <= 1;
                else                axis_in_tlast <= 0;

                // Select Data
                if (type_id == 0) begin // Weight
                    case(tile_id)
                        0: axis_in_tdata <= file_weight_k0_n0[i]; 
                        1: axis_in_tdata <= file_weight_k1_n0[i]; 
                        2: axis_in_tdata <= file_weight_k0_n1[i]; 
                        3: axis_in_tdata <= file_weight_k1_n1[i]; 
                    endcase
                end else begin // Input
                    if (tile_id == 0) axis_in_tdata <= file_input_k0[i];
                    else              axis_in_tdata <= file_input_k1[i];
                end
                
                @(posedge clk); 
            end
            axis_in_tvalid <= 0;
            axis_in_tlast <= 0;
        end
    endtask

    integer err_cnt = 0;

    task check_output_stream;
        input integer n_idx;
        integer i;
        reg [63:0] expected;
        begin
            $display("[TB] Checking Output Stream for N=%0d...", n_idx);
            axis_out_tready <= 1;
            
            // Expect M * 2 words
            for (i = 0; i < M_DIM; i = i + 1) begin
                // Wait for valid
                while (!axis_out_tvalid) @(posedge clk);
                
                if (n_idx == 0) expected = file_golden_n0[i];
                else            expected = file_golden_n1[i];
                
                if (axis_out_tdata !== expected) begin
                    $display("[FAIL] Stream Word %0d: Exp %h, Got %h", i, expected, axis_out_tdata);
                    err_cnt = err_cnt + 1;
                end
                
                @(posedge clk); 
            end
            $display("[TB] Output Stream Check Done.");
            axis_out_tready <= 0;
            
        end
    endtask

    // --- 6. Main Scenario ---
    initial begin
        $dumpfile("top_verify.vcd");
        $dumpvars(0, deit_accelerator_top_tb);

        clk = 0; rst_n = 0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_arvalid=0; s_axi_rready=0;
        axis_in_tvalid=0; axis_in_tlast=0; axis_out_tready=0;
        s_axi_awaddr = 0; s_axi_araddr = 0;

        #20 rst_n = 1;
        #50;

        $display("=== START SYSTEM TOP VERIFICATION ===");

        // 1. Config Global & PPU
        $display("[TB] 1. Configuring Registers...");
        // [FIX] CRITICAL: 先释放软复位 (Bit 1 = 1)，否则 Input Buffer 无法写入！
        // 0x02 = 00...0010 (Soft Reset = 1, Start = 0)
        axi_lite_write(6'h00, 2); 
        
        axi_lite_write(6'h08, 32);  // M_DIM = 32
        
        // PPU Params
        axi_lite_write(6'h14, file_config[0]); 
        axi_lite_write(6'h18, file_config[1]); 
        axi_lite_write(6'h1C, file_config[2]); 
        axi_lite_write(6'h20, file_config[3]); // Bias
        
        // --- LOOP 1: Compute Output Tile N=0 ---
        $display("\n[TB] === Processing Output Tile N=0 ===");
        
        // 2.1 Process K=0
        $display("[TB] -> Step K=0: Pre-load Input, Load Weight & Compute");
        axi_lite_write(6'h24, 0); // Output Enable = 0
        axi_lite_write(6'h0C, 0); // ACC Mode = 0 (Overwrite)
        
        // Strategy: 
        // 1. Send Inputs (Safe in IDLE)
        send_stream_data(1, 0); // Type=In, Tile=k0
        
        // 2. Trigger Start & Send Weights concurrently
        fork
            axi_lite_write(6'h00, 3); // Start=1, Rst=1
            begin
                // Snooping internal signal to sync with Hardware Start
                wait(dut.u_control.o_ap_start == 1);
                repeat(5) @(posedge clk); // [FIX] 增加安全余量，等待 dma_req 拉高
                send_stream_data(0, 0); // Type=Wt, Tile={k0, n0}
            end
        join
        
        // Wait for compute to finish (M=32 + Latency ~30 + Drain) -> ~100 cycles
        #1500; 

        // 2.2 Process K=1
        $display("[TB] -> Step K=1: Pre-load Input, Load Weight & Compute (Accumulate)");
        axi_lite_write(6'h24, 1); // Output Enable = 1
        axi_lite_write(6'h0C, 1); // ACC Mode = 1 (Accumulate)
        
        send_stream_data(1, 1); // Type=In, Tile=k1 (Pre-load)
        
        fork
            axi_lite_write(6'h00, 3); // Start
            begin
                wait(dut.u_control.o_ap_start == 1);
                repeat(5) @(posedge clk); // [FIX] 增加安全余量，等待 dma_req 拉高
                send_stream_data(0, 1); // Type=Wt, Tile={k1, n0}
            end
            // Check Output concurrently (PPU will output after compute)
            check_output_stream(0);
        join
        
        #200;

        // --- LOOP 2: Compute Output Tile N=1 ---
        $display("\n[TB] === Processing Output Tile N=1 ===");
        
        // 3.1 Process K=0
        $display("[TB] -> Step K=0: Reuse Input, Load Weight & Compute");
        axi_lite_write(6'h24, 0); 
        axi_lite_write(6'h0C, 0); 
        
        // Note: Inputs are NOT re-sent here. We assume they are still in Buffer?
        // Actually, buffer is simple. If we don't swap, we just overwrite.
        // But for N loop, K inputs are the same! 
        // We must RE-SEND inputs because we overwrote K0 with K1 in the buffer during previous step.
        // Wait, input buffer size? 
        // Simplest strategy: Just reload inputs every time.
        send_stream_data(1, 0); // Reload Input k0
        
        fork
            axi_lite_write(6'h00, 3);
            begin
                wait(dut.u_control.o_ap_start == 1);
                repeat(5) @(posedge clk); // [FIX] 增加安全余量，等待 dma_req 拉高
                send_stream_data(0, 2); // Wt {k0, n1}
            end
        join
        #1500;

        // 3.2 Process K=1
        $display("[TB] -> Step K=1: Reuse Input, Load Weight & Compute");
        axi_lite_write(6'h24, 1); 
        axi_lite_write(6'h0C, 1); 
        
        send_stream_data(1, 1); // Reload Input k1
        
        fork
            axi_lite_write(6'h00, 3); 
            begin
                wait(dut.u_control.o_ap_start == 1);
                repeat(5) @(posedge clk); // [FIX] 增加安全余量，等待 dma_req 拉高
                send_stream_data(0, 3); // Wt {k1, n1}
            end
            check_output_stream(1); 
        join
        
        #200;

        if (err_cnt == 0) $display("\n=== SUCCESS: Full System Verified! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        
        $finish;
    end

endmodule