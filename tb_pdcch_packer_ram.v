timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Testbench: tb_pdcch_packer_ram
// DUT      : pdcch_packer_ram
//
// Muc dich:
//   - Kiem tra PDCCH packer ghi truc tiep DATA/DMRS vao RAM.
//   - Kiem tra Aggregation Level: 1, 2, 4, 8, 16.
//   - Kiem tra thu tu 12 RE trong moi REG.
//   - Kiem tra noi dung RAM tai tung dia chi.
//   - Kiem tra so luong DATA/DMRS/RE da ghi.
//   - Kiem tra ram_write_done.
//   - Kiem tra cfg_ready/busy.
//   - Kiem tra AL khong hop le.
//   - Kiem tra reset giua packet.
//
// Quy uoc PDCCH:
//   - 1 CCE = 6 REG.
//   - 1 REG = 12 RE.
//   - 1 CCE = 72 RE.
//   - Trong moi REG:
//       RE 0  : DATA
//       RE 1  : DMRS
//       RE 2  : DATA
//       RE 3  : DATA
//       RE 4  : DATA
//       RE 5  : DMRS
//       RE 6  : DATA
//       RE 7  : DATA
//       RE 8  : DATA
//       RE 9  : DMRS
//       RE 10 : DATA
//       RE 11 : DATA
//
// So sample:
//   - DATA = 54 * AL
//   - DMRS = 18 * AL
//   - RAM  = 72 * AL
//
// Luu y:
//   - DUT ket thuc packet theo Aggregation Level, khong phu thuoc TLAST input.
//   - RAM read port cua DUT la asynchronous, vi vay testbench dat dia chi roi
//     #1 moi kiem tra ram_rd_data.
//   - Input duoc thay doi sau posedge (#1) de tranh race voi DUT.
//////////////////////////////////////////////////////////////////////////////////

module tb_pdcch_packer_ram;

    //==========================================================================
    // Clock / Reset
    //==========================================================================
    reg aclk   = 1'b0;
    reg aresetn = 1'b0;

    // Clock 100 MHz
    always #5 aclk = ~aclk;

    //==========================================================================
    // Configuration
    //==========================================================================
    reg       cfg_valid = 1'b0;
    wire      cfg_ready;
    reg [4:0] cfg_aggregation_level = 5'd0;

    //==========================================================================
    // DATA input stream
    //==========================================================================
    reg  [31:0] s_axis_data_tdata  = 32'd0;
    reg         s_axis_data_tvalid = 1'b0;
    reg         s_axis_data_tlast  = 1'b0;
    wire        s_axis_data_tready;

    //==========================================================================
    // DMRS input stream
    //==========================================================================
    reg  [31:0] s_axis_dmrs_tdata  = 32'd0;
    reg         s_axis_dmrs_tvalid = 1'b0;
    reg         s_axis_dmrs_tlast  = 1'b0;
    wire        s_axis_dmrs_tready;

    //==========================================================================
    // RAM read port
    //==========================================================================
    reg  [10:0] ram_rd_addr = 11'd0;
    wire [31:0] ram_rd_data;

    //==========================================================================
    // Status
    //==========================================================================
    wire        busy;
    wire        ram_write_done;
    wire [10:0] ram_sample_count;

    //==========================================================================
    // DUT
    //==========================================================================
    pdcch_packer_ram dut (
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

        .ram_rd_addr           (ram_rd_addr),
        .ram_rd_data           (ram_rd_data),

        .busy                  (busy),
        .ram_write_done        (ram_write_done),
        .ram_sample_count      (ram_sample_count)
    );

    //==========================================================================
    // Bien thong ke
    //==========================================================================
    integer passed        = 0;
    integer total_checked = 0;

    integer al;
    integer expected_total;
    integer expected_data;
    integer expected_dmrs;

    integer nd;
    integer nm;
    integer cycles;

    integer addr;
    integer re_pos;
    integer reg_pos;

    reg [31:0] expected_value;
    reg        expected_is_dmrs;

    //==========================================================================
    // Reset DUT
    //==========================================================================
    task reset_dut;
        begin
            aresetn = 1'b0;

            cfg_valid = 1'b0;
            cfg_aggregation_level = 5'd0;

            s_axis_data_tvalid = 1'b0;
            s_axis_data_tlast  = 1'b0;
            s_axis_data_tdata  = 32'd0;

            s_axis_dmrs_tvalid = 1'b0;
            s_axis_dmrs_tlast  = 1'b0;
            s_axis_dmrs_tdata  = 32'd0;

            ram_rd_addr = 11'd0;

            repeat (3) @(posedge aclk);
            #1;

            if (cfg_ready !== 1'b1 ||
                busy !== 1'b0 ||
                ram_write_done !== 1'b0)
            begin
                $fatal(1, "FAIL: DUT khong ve dung trang thai IDLE sau reset");
            end

            aresetn = 1'b1;
        end
    endtask

    //==========================================================================
    // Task: chay mot packet
    //
    // AL hop le: 1, 2, 4, 8, 16
    //==========================================================================
    task run_packet;
        input integer test_al;

        begin
            al = test_al;

            expected_total = 72 * al;
            expected_data  = 54 * al;
            expected_dmrs  = 18 * al;

            nd     = 0;
            nm     = 0;
            cycles = 0;

            $display("------------------------------------------------------------");
            $display("BAT DAU TEST RAM: AL=%0d", al);
            $display("Expected DATA=%0d DMRS=%0d RAM samples=%0d",
                     expected_data, expected_dmrs, expected_total);

            // ---------------------------------------------------------------
            // Kiem tra DUT dang san sang
            // ---------------------------------------------------------------
            if (cfg_ready !== 1'b1)
                $fatal(1, "FAIL: cfg_ready = 0 truoc packet");

            // ---------------------------------------------------------------
            // Gui configuration
            // ---------------------------------------------------------------
            cfg_aggregation_level = al[4:0];
            cfg_valid = 1'b1;

            @(posedge aclk);
            #1;

            cfg_valid = 1'b0;

            // ---------------------------------------------------------------
            // Sau khi nhan config, DUT phai vao PACK
            // ---------------------------------------------------------------
            if (busy !== 1'b1 || cfg_ready !== 1'b0)
                $fatal(1, "FAIL: DUT khong vao ST_PACK");

            // ---------------------------------------------------------------
            // Phat ca DATA va DMRS lien tuc.
            //
            // DUT tu chon stream nao duoc handshake dua tren vi tri RE.
            // ---------------------------------------------------------------
            s_axis_data_tvalid = 1'b1;
            s_axis_dmrs_tvalid = 1'b1;

            s_axis_data_tdata = 32'h10000000;
            s_axis_dmrs_tdata = 32'hD0000000;

            s_axis_data_tlast = 1'b0;
            s_axis_dmrs_tlast = 1'b0;

            while ((nd < expected_data ||
                    nm < expected_dmrs ||
                    busy) &&
                   cycles < 20000)
            begin
                @(posedge aclk);

                // -----------------------------------------------------------
                // DATA handshake
                // -----------------------------------------------------------
                if (s_axis_data_tvalid && s_axis_data_tready) begin
                    nd = nd + 1;

                    // Sample DATA tiep theo
                    #1;
                    s_axis_data_tdata = 32'h10000000 + nd;
                end

                // -----------------------------------------------------------
                // DMRS handshake
                // -----------------------------------------------------------
                if (s_axis_dmrs_tvalid && s_axis_dmrs_tready) begin
                    nm = nm + 1;

                    // Sample DMRS tiep theo
                    #1;
                    s_axis_dmrs_tdata = 32'hD0000000 + nm;
                end

                cycles = cycles + 1;

                // -----------------------------------------------------------
                // Trong ST_PACK chi mot trong hai READY duoc phep = 1.
                // -----------------------------------------------------------
                if (busy) begin
                    if ((s_axis_data_tready === 1'b1) &&
                        (s_axis_dmrs_tready === 1'b1))
                    begin
                        $fatal(1,
                               "FAIL: DATA va DMRS cung READY tai cycle %0d",
                               cycles);
                    end
                end
            end

            // Tat input sau khi packet ket thuc
            #1;
            s_axis_data_tvalid = 1'b0;
            s_axis_dmrs_tvalid = 1'b0;
            s_axis_data_tlast  = 1'b0;
            s_axis_dmrs_tlast  = 1'b0;

            // ---------------------------------------------------------------
            // Kiem tra timeout
            // ---------------------------------------------------------------
            if (cycles >= 20000)
                $fatal(1, "FAIL: timeout AL=%0d", al);

            // ---------------------------------------------------------------
            // Kiem tra so luong input
            // ---------------------------------------------------------------
            if (nd != expected_data)
                $fatal(1,
                       "FAIL: DATA count = %0d, expected = %0d",
                       nd, expected_data);

            if (nm != expected_dmrs)
                $fatal(1,
                       "FAIL: DMRS count = %0d, expected = %0d",
                       nm, expected_dmrs);

            // ---------------------------------------------------------------
            // Kiem tra RAM sample count
            // ---------------------------------------------------------------
            if (ram_sample_count !== expected_total[10:0])
                $fatal(1,
                       "FAIL: ram_sample_count = %0d, expected = %0d",
                       ram_sample_count, expected_total);

            // ---------------------------------------------------------------
            // ram_write_done phai duoc assert khi packet vua ghi xong.
            // Tai thoi diem hien tai co the da ve 0 neu da qua them cycle.
            // Vi vay chi can kiem tra busy/cfg_ready o day.
            // ---------------------------------------------------------------
            if (busy !== 1'b0 || cfg_ready !== 1'b1)
                $fatal(1, "FAIL: DUT khong quay lai IDLE sau packet");

            // ---------------------------------------------------------------
            // Doc lai tung dia chi RAM va kiem tra noi dung.
            //
            // Thu tu RAM:
            //   DATA, DMRS, DATA, DATA, DATA, DMRS, ...
            // ---------------------------------------------------------------
            for (addr = 0; addr < expected_total; addr = addr + 1) begin

                ram_rd_addr = addr[10:0];
                #1;

                re_pos  = addr % 12;
                reg_pos = addr / 12;

                expected_is_dmrs =
                    (re_pos == 1) ||
                    (re_pos == 5) ||
                    (re_pos == 9);

                if (expected_is_dmrs)
                    expected_value = 32'hD0000000 +
                                     ((reg_pos * 3) +
                                      ((re_pos == 1) ? 0 :
                                       (re_pos == 5) ? 1 : 2));
                else
                    expected_value = 32'h10000000 +
                                     ((reg_pos * 9) +
                                      re_pos -
                                      ((re_pos > 1) ? 1 : 0) -
                                      ((re_pos > 5) ? 1 : 0) -
                                      ((re_pos > 9) ? 1 : 0));

                total_checked = total_checked + 1;

                if (ram_rd_data !== expected_value) begin
                    $fatal(1,
                           "FAIL RAM: AL=%0d addr=%0d REG=%0d RE=%0d data=%h expected=%h",
                           al,
                           addr,
                           reg_pos,
                           re_pos,
                           ram_rd_data,
                           expected_value);
                end
            end

            // ---------------------------------------------------------------
            // Kiem tra mot so dia chi bien
            // ---------------------------------------------------------------
            ram_rd_addr = 11'd0;
            #1;

            if (ram_rd_data !== 32'h10000000)
                $fatal(1, "FAIL: RAM[0] sai");

            ram_rd_addr = (expected_total - 1);
            #1;

            // RE 11 la DATA cuoi cua REG -> sample DATA cuoi.
            if (ram_rd_data !==
                (32'h10000000 + expected_data - 1))
            begin
                $fatal(1, "FAIL: RAM[last] sai");
            end

            passed = passed + 1;

            $display("PASS: AL=%0d DATA=%0d DMRS=%0d RAM=%0d cycles=%0d",
                     al, nd, nm, ram_sample_count, cycles);
        end
    endtask

    //==========================================================================
    // Task: kiem tra AL khong hop le
    //==========================================================================
    task invalid_al;
        input [4:0] test_al;

        begin
            cfg_aggregation_level = test_al;
            cfg_valid = 1'b1;

            @(posedge aclk);
            #1;

            cfg_valid = 1'b0;

            // AL sai phai bi bo qua, DUT van o IDLE.
            if (cfg_ready !== 1'b1 ||
                busy !== 1'b0 ||
                ram_write_done !== 1'b0)
            begin
                $fatal(1, "FAIL: DUT chap nhan AL khong hop le = %0d",
                       test_al);
            end

            passed = passed + 1;

            $display("PASS: reject AL=%0d", test_al);
        end
    endtask

    //==========================================================================
    // Test reset giua packet
    //==========================================================================
    task reset_middle_of_packet;
        begin
            $display("------------------------------------------------------------");
            $display("BAT DAU TEST RESET GIUA PACKET");

            cfg_aggregation_level = 5'd4;
            cfg_valid = 1'b1;

            @(posedge aclk);
            #1;

            cfg_valid = 1'b0;

            if (busy !== 1'b1)
                $fatal(1, "FAIL: DUT khong vao PACK");

            s_axis_data_tvalid = 1'b1;
            s_axis_dmrs_tvalid = 1'b1;

            s_axis_data_tdata = 32'h10000000;
            s_axis_dmrs_tdata = 32'hD0000000;

            // Cho DUT ghi mot vai sample
            repeat (10)
                @(posedge aclk);

            #1;

            // Reset khi dang PACK
            aresetn = 1'b0;

            repeat (3)
                @(posedge aclk);

            #1;

            if (cfg_ready !== 1'b1 ||
                busy !== 1'b0 ||
                ram_write_done !== 1'b0)
            begin
                $fatal(1, "FAIL: reset giua packet khong dua DUT ve IDLE");
            end

            aresetn = 1'b1;

            s_axis_data_tvalid = 1'b0;
            s_axis_dmrs_tvalid = 1'b0;

            passed = passed + 1;

            $display("PASS: reset giua packet");
        end
    endtask

    //==========================================================================
    // Main test sequence
    //==========================================================================
    initial begin

        $display("============================================================");
        $display("             TEST PDCCH PACKER WITH RAM");
        $display("============================================================");

        // ---------------------------------------------------------------
        // Reset ban dau
        // ---------------------------------------------------------------
        reset_dut;

        // ---------------------------------------------------------------
        // Test tat ca Aggregation Level hop le
        // ---------------------------------------------------------------
        run_packet(1);
        run_packet(2);
        run_packet(4);
        run_packet(8);
        run_packet(16);

        // ---------------------------------------------------------------
        // Test AL khong hop le
        // ---------------------------------------------------------------
        invalid_al(0);
        invalid_al(3);
        invalid_al(5);
        invalid_al(31);

        // ---------------------------------------------------------------
        // Test reset giua packet
        // ---------------------------------------------------------------
        reset_middle_of_packet;

        // ---------------------------------------------------------------
        // Sau reset giua packet, chay lai mot packet binh thuong
        // ---------------------------------------------------------------
        run_packet(2);

        // ---------------------------------------------------------------
        // Kiem tra khong co output/done/busy du sau packet
        // ---------------------------------------------------------------
        repeat (3) begin
            @(posedge aclk);
            #1;

            if (busy !== 1'b0 ||
                ram_write_done !== 1'b0 ||
                cfg_ready !== 1'b1)
            begin
                $fatal(1, "FAIL: DUT con trang thai thua sau packet");
            end
        end

        $display("============================================================");
        $display("KET THUC: PASS %0d TEST, %0d DIA CHI RAM DA KIEM TRA",
                 passed, total_checked);
        $display("============================================================");

        $finish;
    end

    //==========================================================================
    // Global timeout
    //==========================================================================
    initial begin
        #20000000;
        $fatal(1, "FAIL: GLOBAL TIMEOUT");
    end

endmodule
