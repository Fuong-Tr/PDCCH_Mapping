`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/03/2026 02:03:03 PM
// Design Name: 
// Module Name: tb_cce_to_reg_mapper
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module tb_cce_to_reg_mapper_optimized;

    localparam integer MAX_RB       = 108;
    localparam integer BITMAP_WIDTH = MAX_RB * 14;

    reg                     clk;
    reg                     rst_n;

    reg  [63:0]             s_axis_cfg_tdata;
    reg                     s_axis_cfg_tvalid;
    wire                    s_axis_cfg_tready;

    wire [BITMAP_WIDTH-1:0] pdcch_rb_bitmap;
    wire                    pdcch_rb_bitmap_valid;
    reg                     pdcch_rb_bitmap_ready;

    integer wait_cycles;

    // -------------------------------------------------------------------------
    // DUT: khoi CCE-to-REG mapper can kiem tra.
    // -------------------------------------------------------------------------
    cce_to_reg_mapper #(
        .MAX_RB(MAX_RB)
    ) dut (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .s_axis_cfg_tdata      (s_axis_cfg_tdata),
        .s_axis_cfg_tvalid     (s_axis_cfg_tvalid),
        .s_axis_cfg_tready     (s_axis_cfg_tready),
        .pdcch_rb_bitmap       (pdcch_rb_bitmap),
        .pdcch_rb_bitmap_valid (pdcch_rb_bitmap_valid),
        .pdcch_rb_bitmap_ready (pdcch_rb_bitmap_ready)
    );

    // Clock 100 MHz, chu ky 10 ns.
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // In cac tin hieu quan trong sau moi suon duong.
    // Delay 1 ns de doi cac thanh ghi nonblocking cua DUT cap nhat xong.
    always @(posedge clk) begin
        #1;
        $display(
            "time=", $time,
            " rst_n=", rst_n,
            " cfg_valid=", s_axis_cfg_tvalid,
            " cfg_ready=", s_axis_cfg_tready,
            " state=", dut.state,
            " bitmap_valid=", pdcch_rb_bitmap_valid
        );
    end

    initial begin

        rst_n                 = 1'b0;
        s_axis_cfg_tdata      = 64'd0;
        s_axis_cfg_tvalid     = 1'b0;
        pdcch_rb_bitmap_ready = 1'b0;

        wait_cycles           = 0;

        // Cau hinh gui vao DUT:
        //   CCE_start         = 0
        //   AL code           = 0, nghia la AL = 1
        //   L                 = 2
        //   interleaver_mode  = 1
        //   R                 = 2
        //   CORESET RB        = 24
        //   shift_index       = 2
        //   start_symbol      = 2
        //   duration          = 2
        // Word: 64'h0000_0840_2061_5000

        // Bitmap mong doi co dung 6 REG:
        //   Symbol 2: RB 2, RB 3, RB 14
        //   Symbol 3: RB 2, RB 3, RB 14

        // ---------------------------------------------------------------------
        // RESET DONG BO
        // ---------------------------------------------------------------------
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;

        // Cho mot suon duong de quan sat DUT o IDLE.
        @(posedge clk);
        #1;

        if (s_axis_cfg_tready !== 1'b1) begin
            $display("TEST FAIL: CFG_READY KHONG LEN SAU RESET");
            $display("KET THUC TEST");
            $fatal(1, "DUNG MO PHONG DO LOI CFG_READY");
        end

        // ---------------------------------------------------------------------
        // GUI MOT WORD CAU HINH 64 BIT
        // ---------------------------------------------------------------------
        s_axis_cfg_tdata  = 64'h0000_0C60_2093_5900;
        s_axis_cfg_tvalid = 1'b1;

        // Tai suon duong tiep theo, valid va ready cung bang 1.
        @(posedge clk);
        #1;

        // Ha valid sau khi handshake input hoan thanh.
        s_axis_cfg_tvalid = 1'b0;
        s_axis_cfg_tdata  = 64'd0;

        if (dut.state === 3'd0) begin
            $display("TEST FAIL: FSM VAN O IDLE SAU HANDSHAKE INPUT");
            $display("KET THUC TEST");
            $fatal(1, "DUNG MO PHONG DO LOI HANDSHAKE INPUT");
        end

        // ---------------------------------------------------------------------
        // CHO DUT XU LY HET
        // Ban toi uu phai hoan thanh testcase nay khong qua 10 chu ky xu ly.
        // ---------------------------------------------------------------------
        wait_cycles = 0;

        while ((pdcch_rb_bitmap_valid !== 1'b1) &&
               (wait_cycles < 10)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end


        repeat (2) begin
            @(posedge clk);
            #1;


        // ---------------------------------------------------------------------
        // HANDSHAKE OUTPUT
        // ---------------------------------------------------------------------
        pdcch_rb_bitmap_ready = 1'b1;

        @(posedge clk);
        #1;

        pdcch_rb_bitmap_ready = 1'b0;

        repeat (2) @(posedge clk);
        $finish;
    end
    
    end

endmodule
