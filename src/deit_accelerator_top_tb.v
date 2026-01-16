// -----------------------------------------------------------------------------
// 文件名: src/deit_accelerator_top_tb.v
// 描述: DeiT Accelerator 全系统验证 (Fixed Address Width)
//       - 修复了 AXI 地址位宽为 6-bit 以支持 PPU Bias/Enable 寄存器
//       - 包含完整的系统级仿真流程
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module deit_accelerator_top_tb;

    // --- 1. 参数与时钟 ---
    localparam C_S_AXI_DATA_WIDTH = 32;
    // [FIX] 修改为 6 (支持 0x00 - 0x3F 地址空间)
    localparam C_S_AXI_ADDR_WIDTH = 6;
    
    // Matrix Dims
    localparam M_DIM = 32;
    localparam K_DIM = 24;
    localparam N_DIM = 32;

    reg clk, rst_n;
    always #5 clk = ~clk; // 100MHz

    // --- 2. 接口信号 ---
    // AXI-Lite
    // [FIX] 使用参数化位宽，而不是硬编码 [4:0]
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
    // [FIX] 使用参数化位宽
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
    // 注意：TB 里的参数要传递给 DUT，虽然 DUT 默认也是 6，但显式传递是个好习惯
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
        // 使用相对路径，确保在根目录运行 ./src/simulate_top.sh 时能找到
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
        // [FIX] 使用参数化位宽，支持 6-bit 地址
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

    // DMA Send Task
    task send_stream_data;
        input [1:0] type_id; // 0: Weight, 1: Input
        input integer tile_id; // For weight: {k, n}, for input: k
        integer i;
        integer limit;
        begin
            if (type_id == 0) limit = 24; // Weight
            else              limit = 48; // Input

            for (i = 0; i < limit; i = i + 1) begin
                axis_in_tvalid <= 1;
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
            for (i = 0; i < M_DIM*2; i = i + 1) begin
                // Wait for valid
                while (!axis_out_tvalid) @(posedge clk);
                
                if (n_idx == 0) expected = file_golden_n0[i];
                else            expected = file_golden_n1[i];
                
                if (axis_out_tdata !== expected) begin
                    $display("[FAIL] Stream Word %0d: Exp %h, Got %h", i, expected, axis_out_tdata);
                    err_cnt++;
                end
                
                @(posedge clk); 
            end
            axis_out_tready <= 0;
            $display("[TB] Output Stream Check Done.");
        end
    endtask

    // --- 6. Main Scenario ---
    initial begin
        $dumpfile("top_verify.vcd");
        $dumpvars(0, deit_accelerator_top_tb);

        clk = 0; rst_n = 0;
        s_axi_awvalid=0; s_axi_wvalid=0; s_axi_bready=0; s_axi_arvalid=0; s_axi_rready=0;
        axis_in_tvalid=0; axis_in_tlast=0; axis_out_tready=0;
        // 初始化地址信号，防止 X 态
        s_axi_awaddr = 0; s_axi_araddr = 0;

        #20 rst_n = 1;
        #50;

        $display("=== START SYSTEM TOP VERIFICATION ===");

        // 1. Config Global & PPU
        $display("[TB] 1. Configuring Registers...");
        // [FIX] Address Width is now 6-bit. 
        // 0x08 -> 6'h08
        axi_lite_write(6'h08, 32);  // M_DIM = 32
        
        // PPU Params
        axi_lite_write(6'h14, file_config[0]); // Mult
        axi_lite_write(6'h18, file_config[1]); // Shift
        axi_lite_write(6'h1C, file_config[2]); // ZP
        // [FIX] Bias is at 0x20 (Requires 6-bit address!)
        axi_lite_write(6'h20, file_config[3]); // Bias
        
        // --- LOOP 1: Compute Output Tile N=0 ---
        $display("\n[TB] === Processing Output Tile N=0 ===");
        
        // 2.1 Process K=0
        $display("[TB] -> Step K=0: Load Weight & Compute (Overwrite)");
        // Disable Output (We don't want partial sums streamed out)
        axi_lite_write(6'h24, 0); // Output Enable = 0
        
        axi_lite_write(6'h0C, 0); // ACC Mode = 0 (Overwrite)
        axi_lite_write(6'h00, 1); // Start
        
        send_stream_data(0, 0); // Type=Wt, Tile={k0, n0}
        #500; 
        send_stream_data(1, 0); // Type=In, Tile=k0
        #1000;

        // 2.2 Process K=1
        $display("[TB] -> Step K=1: Load Weight & Compute (Accumulate)");
        // Enable Output (This is the final tile)
        axi_lite_write(6'h24, 1); // Output Enable = 1
        
        axi_lite_write(6'h0C, 1); // ACC Mode = 1 (Accumulate)
        axi_lite_write(6'h00, 1); // Start
        
        send_stream_data(0, 1); // Type=Wt, Tile={k1, n0}
        #500;
        
        // Parallel Block: Send Data & Check Output
        fork
            begin
                send_stream_data(1, 1); // Type=In, Tile=k1
            end
            begin
                // Output check logic
                check_output_stream(0);
            end
        join
        #200;

        // --- LOOP 2: Compute Output Tile N=1 ---
        $display("\n[TB] === Processing Output Tile N=1 ===");
        
        // 3.1 Process K=0
        $display("[TB] -> Step K=0: Load Weight & Compute (Overwrite)");
        axi_lite_write(6'h24, 0); // Disable Output
        axi_lite_write(6'h0C, 0); // Mode Overwrite
        axi_lite_write(6'h00, 1); // Start
        
        send_stream_data(0, 2); // Wt {k0, n1}
        #500;
        send_stream_data(1, 0); // In k0 (Reuse Input Tile 0)
        #1000;

        // 3.2 Process K=1
        $display("[TB] -> Step K=1: Load Weight & Compute (Accumulate)");
        axi_lite_write(6'h24, 1); // Enable Output
        axi_lite_write(6'h0C, 1); // Mode Acc
        axi_lite_write(6'h00, 1); // Start
        
        send_stream_data(0, 3); // Wt {k1, n1}
        #500;
        
        fork
            send_stream_data(1, 1); // In k1
            check_output_stream(1); // Check Golden N=1
        join
        
        #200;

        if (err_cnt == 0) $display("\n=== SUCCESS: Full System Verified! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        
        $finish;
    end

endmodule