// -----------------------------------------------------------------------------
// 文件名: src/axi_lite_control_tb.v
// 描述: AXI-Lite 接口自检 Testbench
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module axi_lite_control_tb;

    // --- Clock & Reset ---
    reg clk, rst_n;
    always #5 clk = ~clk; // 100MHz

    // --- AXI Interface Signals ---
    reg  [4:0]  s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [4:0]  s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // --- User Signals ---
    wire        o_ap_start;
    wire        o_soft_rst_n;
    wire [31:0] o_cfg_compute_cycles;
    wire        o_cfg_acc_mode;
    reg         i_ap_done;
    reg         i_ap_idle;
    wire [15:0] o_ppu_mult;
    wire [4:0]  o_ppu_shift;
    wire [7:0]  o_ppu_zp;
    wire [31:0] o_ppu_bias;
    // --- DUT Instantiation ---
    axi_lite_control dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .o_ap_start(o_ap_start), .o_soft_rst_n(o_soft_rst_n),
        .o_cfg_compute_cycles(o_cfg_compute_cycles), .o_cfg_acc_mode(o_cfg_acc_mode),
        .i_ap_done(i_ap_done), .i_ap_idle(i_ap_idle),
        .o_ppu_mult(o_ppu_mult), .o_ppu_shift(o_ppu_shift), .o_ppu_zp(o_ppu_zp), .o_ppu_bias(o_ppu_bias)
    
    );

    // --- AXI Tasks (模拟 Master 行为) ---
    task axi_write;
        input [4:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            s_axi_awaddr <= addr;
            s_axi_awvalid <= 1;
            s_axi_wdata <= data;
            s_axi_wstrb <= 4'hF;
            s_axi_wvalid <= 1;
            s_axi_bready <= 1;
            
            // Wait for handshake
            wait(s_axi_awready && s_axi_wready);
            @(posedge clk);
            s_axi_awvalid <= 0;
            s_axi_wvalid <= 0;
            
            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready <= 0;
        end
    endtask

    task axi_read;
        input [4:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            s_axi_araddr <= addr;
            s_axi_arvalid <= 1;
            s_axi_rready <= 1;
            
            wait(s_axi_arready);
            @(posedge clk);
            s_axi_arvalid <= 0;
            
            wait(s_axi_rvalid);
            data = s_axi_rdata;
            @(posedge clk);
            s_axi_rready <= 0;
        end
    endtask

    // --- Main Verification Flow ---
    reg [31:0] read_val;
    integer err_cnt = 0;

    initial begin
        $dumpfile("axi_lite_verify.vcd");
        $dumpvars(0, axi_lite_control_tb);

        // Init
        clk = 0; rst_n = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        i_ap_done = 0; i_ap_idle = 1;

        #20 rst_n = 1;
        #20;

        $display("=== START AXI-LITE VERIFICATION ===");

        // --- CP1: Version Check ---
        axi_read(5'h10, read_val);
        if (read_val === 32'h20260116) $display("[PASS] CP1: Version ID Matches.");
        else begin $display("[FAIL] CP1: Version Mismatch. Got %h", read_val); err_cnt=err_cnt+1; end

        // --- CP2: Config Registers ---
        axi_write(5'h08, 32'd197); // Set K_DIM
        axi_write(5'h0C, 32'd1);   // Set ACC_MODE
        #10;
        if (o_cfg_compute_cycles === 197 && o_cfg_acc_mode === 1) 
            $display("[PASS] CP2: Config Registers Output Correct.");
        else begin $display("[FAIL] CP2: Config Output Error."); err_cnt=err_cnt+1; end

        // --- CP3: Soft Reset Control ---
        axi_write(5'h00, 32'h00000002); // Bit 1 = 1
        #10;
        if (o_soft_rst_n === 1) $display("[PASS] CP3: Soft Reset High.");
        else begin $display("[FAIL] CP3: Soft Reset Failed."); err_cnt=err_cnt+1; end

        // --- CP4: ap_start Auto-Clear ---
        fork
            begin
                axi_write(5'h00, 32'h00000001); // Bit 0 = 1
            end
            begin
                // Monitor output pulse
                wait(o_ap_start == 1);
                @(posedge clk);
                #10;
                if (o_ap_start == 0) $display("[PASS] CP4: ap_start Pulse Auto-Cleared.");
                else begin $display("[FAIL] CP4: ap_start Stuck at 1."); err_cnt=err_cnt+1; end
            end
        join

        // --- CP5: ap_done Sticky & W1C ---
        // Simulate Core Done
        #20 i_ap_done = 1; i_ap_idle = 1;
        #10 i_ap_done = 0; // Pulse ends
        
        // Read Status (Should be 1 even though input pulse is gone)
        axi_read(5'h04, read_val); 
        if (read_val[0] === 1) $display("[PASS] CP5a: ap_done Sticky Bit Set.");
        else begin $display("[FAIL] CP5a: ap_done Sticky Bit Not Set."); err_cnt=err_cnt+1; end

        // Write 1 to Clear
        axi_write(5'h04, 32'h00000001);
        axi_read(5'h04, read_val);
        if (read_val[0] === 0) $display("[PASS] CP5b: ap_done W1C Cleared.");
        else begin $display("[FAIL] CP5b: ap_done Not Cleared."); err_cnt=err_cnt+1; end
        // --- CP6: PPU Config Verification ---
        $display("[TB] CP6: Testing PPU Config Registers...");
        axi_write(5'h14, 32'h0000_0100); // Mult = 256
        axi_write(5'h18, 32'h0000_0008); // Shift = 8
        axi_write(5'h1C, 32'h0000_000A); // ZP = 10
        
        #10;
        if (o_ppu_mult === 256 && o_ppu_shift === 8 && o_ppu_zp === 10) 
            $display("[PASS] CP6: PPU Config Correct.");
        else begin
            $display("[FAIL] CP6: PPU Config Error. Mult=%d, Shift=%d, ZP=%d", o_ppu_mult, o_ppu_shift, o_ppu_zp);
            err_cnt = err_cnt + 1;
        end
        // --- Final Report ---
        if (err_cnt == 0) $display("\n=== SUCCESS: All Checkpoints Passed! ===\n");
        else $display("\n=== FAILURE: Found %0d Errors ===\n", err_cnt);
        
        $finish;
    end

endmodule