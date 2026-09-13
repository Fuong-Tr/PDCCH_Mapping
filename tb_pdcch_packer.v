`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_pdcch_packer
// DUT      : pdcch_packer_minimal
//
// Muc dich:
//   - Kiem tra mapping DATA/DMRS theo tung RE trong 1 REG.
//   - Kiem tra cac Aggregation Level hop le: 1, 2, 4, 8, 16.
//   - Kiem tra AXI-Stream handshake o ca dau vao va dau ra.
//   - Kiem tra stall/back-pressure tai dau ra.
//   - Kiem tra gap tren stream DATA va DMRS.
//   - Kiem tra TLAST dau ra.
//   - Kiem tra AL khong hop le.
//   - Kiem tra reset giua packet.
//
// Quy uoc PDCCH trong testbench:
//   - 1 CCE = 6 REG.
//   - 1 REG = 12 RE.
//   - Moi CCE co 72 RE.
//   - Trong moi REG, DMRS nam tai RE = 1, 5, 9.
//   - Moi REG co 9 DATA RE va 3 DMRS RE.
//
// Cach chay trong Vivado:
//   Add Simulation Sources -> chon tb_pdcch_packer.v lam simulation top -> Run All.
//
// Cach chay voi Icarus:
//   iverilog -g2012 -s tb_pdcch_packer -o sim pdcch_packer.v tb_pdcch_packer.v
//   vvp sim
//   vvp sim +DUMP     // neu muon xuat VCD
//
// Luu y:
//   - Handshake duoc danh gia tai posedge.
//   - Input chi thay doi sau posedge mot khoang #1 de tranh race voi DUT.
//////////////////////////////////////////////////////////////////////////////////

module tb_pdcch_packer;

    //==========================================================================
    // Clock / Reset
    //==========================================================================
    reg aclk = 0;
    reg aresetn = 0;

    // Clock 100 MHz
    always #5 aclk = ~aclk;

    //==========================================================================
    // Configuration interface
    //==========================================================================
    reg        cfg_valid = 0;
    reg [4:0]  cfg_aggregation_level = 0;
    wire       cfg_ready;

    //==========================================================================
    // AXI-Stream DATA input
    //==========================================================================
    reg  [31:0] s_axis_data_tdata  = 0;
    reg         s_axis_data_tvalid = 0;
    reg         s_axis_data_tlast  = 0;
    wire        s_axis_data_tready;

    //==========================================================================
    // AXI-Stream DMRS input
    //==========================================================================
    reg  [31:0] s_axis_dmrs_tdata  = 0;
    reg         s_axis_dmrs_tvalid = 0;
    reg         s_axis_dmrs_tlast  = 0;
    wire        s_axis_dmrs_tready;

    //==========================================================================
    // AXI-Stream output
    //==========================================================================
    wire [31:0] m_axis_re_tdata;
    wire        m_axis_re_tvalid;
    reg         m_axis_re_tready = 0;
    wire        m_axis_re_tlast;
    wire [11:0] m_axis_re_tuser;

    //==========================================================================
    // DUT
    //==========================================================================
    pdcch_packer_minimal dut (
        .aclk                  (aclk),
        .aresetn               (aresetn),

        .cfg_valid             (cfg_valid),
        .cfg_ready             (cfg_ready),
        .cfg_aggregation_level (cfg_aggregation_level),

        .s_axis_data_tdata     (s_axis_data_tdata),
        .s_axis_data_tvalid    (s_axis_data_tvalid),
        .s_axis_data_tready    (s_axis_data_tready),
        .s_axis_data_tlast     (s_axis_data_tlast),

        .s_axis_dmrs_tdata     (s_axis_dmrs_tdata),
        .s_axis_dmrs_tvalid    (s_axis_dmrs_tvalid),
        .s_axis_dmrs_tready    (s_axis_dmrs_tready),
        .s_axis_dmrs_tlast     (s_axis_dmrs_tlast),

        .m_axis_re_tdata       (m_axis_re_tdata),
        .m_axis_re_tvalid      (m_axis_re_tvalid),
        .m_axis_re_tready      (m_axis_re_tready),
        .m_axis_re_tlast       (m_axis_re_tlast),
        .m_axis_re_tuser       (m_axis_re_tuser)
    );

    //==========================================================================
    // Bien thong ke / bien kiem tra
    //==========================================================================
    integer passed        = 0;
    integer total_checked = 0;

    integer nd;         // So DATA sample da handshake
    integer nm;         // So DMRS sample da handshake
    integer no;         // So output RE da handshake
    integer cycles;     // So cycle cua test hien tai
    integer re_pos;     // Vi tri RE trong REG: 0..11
    integer reg_pos;    // Chi so REG hien tai
    integer last_hold;  // So cycle co tinh stall tai RE cuoi

    integer stalls;     // Tong so cycle output bi stall
    integer dgaps;      // Tong gap tren DATA stream
    integer mgaps;      // Tong gap tren DMRS stream

    reg df;             // DATA handshake fire
    reg mf;             // DMRS handshake fire
    reg ofire;          // Output handshake fire
    reg is_dmrs;        // RE hien tai co phai DMRS hay khong

    // Dung de kiem tra output phai giu nguyen khi m_axis_re_tready = 0
    reg        held;
    reg [31:0] held_data;
    reg [11:0] held_user;
    reg        held_last;

    // Gia tri mong doi cua output
    reg [31:0] expected_data;
    reg [11:0] expected_user;

    //==========================================================================
    // Task: Reset DUT
    //==========================================================================
    task reset_dut;
        begin
            aresetn = 0;

            cfg_valid = 0;

            s_axis_data_tvalid = 0;
            s_axis_data_tlast  = 0;

            s_axis_dmrs_tvalid = 0;
            s_axis_dmrs_tlast  = 0;

            m_axis_re_tready = 0;

            repeat (3) @(posedge aclk);
            #1;

            // Sau reset DUT phai quay ve trang thai IDLE
            if (cfg_ready !== 1 ||
                m_axis_re_tvalid !== 0 ||
                s_axis_data_tready !== 0 ||
                s_axis_dmrs_tready !== 0)
            begin
                $fatal(1, "FAIL: reset khong ve IDLE");
            end

            aresetn = 1;
        end
    endtask

    //==========================================================================
    // Task: Chay 1 packet PDCCH
    //
    // al        : Aggregation Level = 1/2/4/8/16
    // stress    : 0 = stream lien tuc, 1 = chen stall/gap
    // omit_last : 1 = khong phat TLAST o input de kiem tra DUT ket thuc theo AL
    //==========================================================================
    task run_packet;
        input integer al;
        input stress;
        input omit_last;

        begin
            $display("------------------------------------------------------------");
            $display("BAT DAU: AL=%0d stress=%0d omit_last=%0d",
                     al, stress, omit_last);

            // DUT chi duoc nhan config moi khi cfg_ready = 1
            if (cfg_ready !== 1)
                $fatal(1, "FAIL: DUT chua san sang");

            cfg_aggregation_level = al[4:0];
            cfg_valid = 1;

            @(posedge aclk);
            #1;
            cfg_valid = 0;

            // Khoi tao bo dem cho packet hien tai
            nd        = 0;
            nm        = 0;
            no        = 0;
            cycles    = 0;
            re_pos    = 0;
            reg_pos   = 0;
            held      = 0;
            last_hold = 0;
            stalls    = 0;
            dgaps     = 0;
            mgaps     = 0;

            // 1 CCE = 72 RE -> tong output = 72 * AL
            while (no < 72 * al && cycles < 30000) begin

                //------------------------------------------------------------------
                // Tao DATA source
                // Moi CCE co 54 DATA RE
                //------------------------------------------------------------------
                if (!s_axis_data_tvalid && nd < 54 * al) begin
                    // stress=1: chu dong tao mot so cycle DATA invalid
                    s_axis_data_tvalid = !stress || cycles[1:0] != 0;
                    s_axis_data_tdata  = 32'h10000000 + nd[31:0];
                    s_axis_data_tlast  = !omit_last && (nd == 54 * al - 1);
                end

                //------------------------------------------------------------------
                // Tao DMRS source
                // Moi CCE co 18 DMRS RE
                //------------------------------------------------------------------
                if (!s_axis_dmrs_tvalid && nm < 18 * al) begin
                    // stress=1: tao gap DMRS theo chu ky de kiem tra DUT cho dung
                    s_axis_dmrs_tvalid = !stress || cycles[2:0] == 3;
                    s_axis_dmrs_tdata  = 32'hD0000000 + nm[31:0];
                    s_axis_dmrs_tlast  = !omit_last && (nm == 18 * al - 1);
                end

                //------------------------------------------------------------------
                // Tao back-pressure tai output
                //------------------------------------------------------------------
                m_axis_re_tready = !stress || cycles[2:0] >= 3;

                // Co tinh stall RE cuoi 3 cycle de kiem tra DUT giu data/TLAST
                if (stress && no == 72 * al - 1 && last_hold < 3) begin
                    m_axis_re_tready = 0;
                    last_hold = last_hold + 1;
                end

                //------------------------------------------------------------------
                // Danh gia tin hieu tai posedge
                //------------------------------------------------------------------
                @(posedge aclk);

                // Trong 1 REG, DMRS tai RE 1, 5, 9
                is_dmrs = (re_pos == 1) || (re_pos == 5) || (re_pos == 9);

                // tuser = {is_dmrs, re_index[3:0], reg_index[6:0]}
                expected_user = {is_dmrs, re_pos[3:0], reg_pos[6:0]};

                // Du lieu mong doi phu thuoc RE dang lay tu DATA hay DMRS
                expected_data = is_dmrs
                              ? 32'hD0000000 + nm[31:0]
                              : 32'h10000000 + nd[31:0];

                //------------------------------------------------------------------
                // Kiem tra cfg_ready trong luc dang PACK
                //------------------------------------------------------------------
                if (cfg_ready !== 0)
                    $fatal(1, "FAIL: cfg_ready trong PACK");

                //------------------------------------------------------------------
                // Kiem tra routing READY
                // Chi stream dang duoc chon moi duoc phep ready
                //------------------------------------------------------------------
                if (s_axis_data_tready !== (!is_dmrs && m_axis_re_tready) ||
                    s_axis_dmrs_tready !== ( is_dmrs && m_axis_re_tready))
                begin
                    $fatal(1, "FAIL: READY sai nguon, RE=%0d", no);
                end

                //------------------------------------------------------------------
                // Kiem tra routing VALID
                //------------------------------------------------------------------
                if (m_axis_re_tvalid !==
                    (is_dmrs ? s_axis_dmrs_tvalid : s_axis_data_tvalid))
                begin
                    $fatal(1, "FAIL: VALID sai nguon");
                end

                //------------------------------------------------------------------
                // Khi output stall, DUT phai giu nguyen DATA/USER/LAST
                //------------------------------------------------------------------
                if (held &&
                    (m_axis_re_tvalid !== 1 ||
                     m_axis_re_tdata  !== held_data ||
                     m_axis_re_tuser  !== held_user ||
                     m_axis_re_tlast  !== held_last))
                begin
                    $fatal(1, "FAIL: output thay doi khi stall");
                end

                //------------------------------------------------------------------
                // Kiem tra gia tri output khi VALID = 1
                //------------------------------------------------------------------
                if (m_axis_re_tvalid) begin
                    if (m_axis_re_tdata !== expected_data ||
                        m_axis_re_tuser !== expected_user ||
                        m_axis_re_tlast !== (no == 72 * al - 1))
                    begin
                        $fatal(1,
                               "FAIL AL=%0d RE=%0d data=%h expected=%h user=%h expected=%h last=%b",
                               al,
                               no,
                               m_axis_re_tdata,
                               expected_data,
                               m_axis_re_tuser,
                               expected_user,
                               m_axis_re_tlast);
                    end
                end

                //------------------------------------------------------------------
                // Luu output neu dang stall de cycle sau so sanh
                //------------------------------------------------------------------
                held      = m_axis_re_tvalid && !m_axis_re_tready;
                held_data = m_axis_re_tdata;
                held_user = m_axis_re_tuser;
                held_last = m_axis_re_tlast;

                //------------------------------------------------------------------
                // Thong ke stress condition
                //------------------------------------------------------------------
                if (held)
                    stalls = stalls + 1;

                if (!is_dmrs && !s_axis_data_tvalid)
                    dgaps = dgaps + 1;

                if (is_dmrs && !s_axis_dmrs_tvalid)
                    mgaps = mgaps + 1;

                //------------------------------------------------------------------
                // Xac dinh handshake tai cycle hien tai
                //------------------------------------------------------------------
                df    = s_axis_data_tvalid && s_axis_data_tready;
                mf    = s_axis_dmrs_tvalid && s_axis_dmrs_tready;
                ofire = m_axis_re_tvalid && m_axis_re_tready;

                // Moi output sample phai tu dung mot trong hai input stream
                if (ofire !== (df || mf) || (df && mf))
                    $fatal(1, "FAIL: handshake khong bao toan mau");

                //------------------------------------------------------------------
                // Cap nhat bo dem source
                //------------------------------------------------------------------
                if (df)
                    nd = nd + 1;

                if (mf)
                    nm = nm + 1;

                //------------------------------------------------------------------
                // Cap nhat vi tri output sau moi handshake thanh cong
                //------------------------------------------------------------------
                if (ofire) begin
                    no = no + 1;

                    if (re_pos == 11) begin
                        re_pos  = 0;
                        reg_pos = reg_pos + 1;
                    end
                    else begin
                        re_pos = re_pos + 1;
                    end
                end

                cycles = cycles + 1;

                // Chi thay input sau posedge de tranh race voi DUT
                #1;

                if (df)
                    s_axis_data_tvalid = 0;

                if (mf)
                    s_axis_dmrs_tvalid = 0;
            end

            //------------------------------------------------------------------
            // Kiem tra packet da chay du so sample
            //------------------------------------------------------------------
            if (no != 72 * al || nd != 54 * al || nm != 18 * al)
            begin
                $fatal(1,
                       "FAIL: timeout/count DATA=%0d DMRS=%0d OUT=%0d",
                       nd, nm, no);
            end

            //------------------------------------------------------------------
            // Neu stress=1 thi phai thuc su tao du stall va gap
            //------------------------------------------------------------------
            if (stress &&
                (stalls == 0 || dgaps == 0 || mgaps == 0 || last_hold != 3))
            begin
                $fatal(1, "FAIL: chua tao du stall/gap");
            end

            //------------------------------------------------------------------
            // Sau packet DUT phai quay lai IDLE
            //------------------------------------------------------------------
            if (cfg_ready !== 1 ||
                m_axis_re_tvalid !== 0 ||
                m_axis_re_tlast !== 0)
            begin
                $fatal(1, "FAIL: ket thuc goi");
            end

            m_axis_re_tready = 0;

            total_checked = total_checked + no;
            passed        = passed + 1;

            $display("PASS: DATA=%0d DMRS=%0d OUT=%0d cycles=%0d stalls=%0d",
                     nd, nm, no, cycles, stalls);
        end
    endtask

    //==========================================================================
    // Task: Kiem tra Aggregation Level khong hop le
    //==========================================================================
    task invalid_al;
        input [4:0] al;

        begin
            cfg_aggregation_level = al;
            cfg_valid = 1;

            @(posedge aclk);
            #1;
            cfg_valid = 0;

            // DUT khong duoc vao PACK voi AL sai
            if (cfg_ready !== 1 || m_axis_re_tvalid !== 0)
                $fatal(1, "FAIL: chap nhan AL sai %0d", al);

            passed = passed + 1;
            $display("PASS: bo qua AL=%0d", al);
        end
    endtask

    //==========================================================================
    // Main test sequence
    //==========================================================================
    initial begin
        $display("============================================================");
        $display("              BAT DAU TEST PDCCH PACKER");
        $display("============================================================");

        // Tuy chon xuat waveform VCD
        if ($test$plusargs("DUMP")) begin
            $dumpfile("tb_pdcch_packer.vcd");
            $dumpvars(0, tb_pdcch_packer);
        end

        @(posedge aclk);
        #1;

        //------------------------------------------------------------------
        // Test 1: Reset
        //------------------------------------------------------------------
        reset_dut;

        //------------------------------------------------------------------
        // Test 2: Tat ca AL, khong stress
        //------------------------------------------------------------------
        run_packet(1,  0, 0);
        run_packet(2,  0, 0);
        run_packet(4,  0, 0);
        run_packet(8,  0, 0);
        run_packet(16, 0, 0);

        //------------------------------------------------------------------
        // Test 3: Tat ca AL, co stall va gap
        //------------------------------------------------------------------
        run_packet(1,  1, 0);
        run_packet(2,  1, 0);
        run_packet(4,  1, 0);
        run_packet(8,  1, 0);
        run_packet(16, 1, 0);

        //------------------------------------------------------------------
        // Test 4: Khong phat TLAST dau vao
        // DUT hien tai ket thuc packet dua tren AL, khong dua vao TLAST input.
        //------------------------------------------------------------------
        run_packet(1, 1, 1);

        //------------------------------------------------------------------
        // Test 5: AL khong hop le
        //------------------------------------------------------------------
        invalid_al(0);
        invalid_al(3);
        invalid_al(31);

        //------------------------------------------------------------------
        // Test 6: Reset giua packet
        // Bat dau packet AL=1, truyen DATA dau tien roi reset khi DUT dang
        // chuan bi xu ly cac RE tiep theo.
        //------------------------------------------------------------------
        cfg_aggregation_level = 1;
        cfg_valid = 1;

        @(posedge aclk);
        #1;
        cfg_valid = 0;

        s_axis_data_tdata  = 32'h12345678;
        s_axis_data_tvalid = 1;
        m_axis_re_tready   = 1;

        @(posedge aclk);

        if (!(s_axis_data_tready && m_axis_re_tvalid))
            $fatal(1, "FAIL: chua tao duoc goi dang do");

        #1;
        reset_dut;

        passed = passed + 1;
        $display("PASS: reset giua goi");

        //------------------------------------------------------------------
        // Test 7: Sau reset giua packet, DUT van phai hoat dong binh thuong
        //------------------------------------------------------------------
        run_packet(2, 1, 0);

        //------------------------------------------------------------------
        // Test 8: Khong duoc con output du sau packet
        //------------------------------------------------------------------
        repeat (5) begin
            @(posedge aclk);
            #1;

            if (m_axis_re_tvalid !== 0 || cfg_ready !== 1)
                $fatal(1, "FAIL: output thua sau goi");
        end

        $display("============================================================");
        $display("KET THUC: PASS %0d TEST, %0d RE DA KIEM TRA",
                 passed, total_checked);
        $display("============================================================");

        $finish;
    end

    //==========================================================================
    // Global timeout de tranh simulation treo vo han
    //==========================================================================
    initial begin
        #20000000;
        $fatal(1, "FAIL: GLOBAL TIMEOUT");
    end

endmodule
