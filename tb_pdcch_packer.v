`timescale 1ns / 1ps

// Testbench pdcch_packer.v; DUT co ten pdcch_packer_minimal.
// Vivado: Add Simulation Sources, dat tb_pdcch_packer lam top, Run All.
// Icarus: iverilog -g2012 -s tb_pdcch_packer -o sim pdcch_packer.v tb_pdcch_packer.v
//         vvp sim          (them +DUMP de xuat VCD)
// Lay handshake tai posedge truoc NBA; chi doi input sau posedge #1.
// Khong dung function hay phep chia lay du. Comment tieng Viet khong dau.
module tb_pdcch_packer;
    reg aclk = 0;
    always #5 aclk = ~aclk;
    reg aresetn = 0, cfg_valid = 0;
    reg [4:0] cfg_aggregation_level = 0;
    wire cfg_ready;
    reg [31:0] s_axis_data_tdata = 0, s_axis_dmrs_tdata = 0;
    reg s_axis_data_tvalid = 0, s_axis_dmrs_tvalid = 0;
    reg s_axis_data_tlast = 0, s_axis_dmrs_tlast = 0;
    wire s_axis_data_tready, s_axis_dmrs_tready;
    wire [31:0] m_axis_re_tdata;
    wire m_axis_re_tvalid, m_axis_re_tlast;
    reg m_axis_re_tready = 0;
    wire [11:0] m_axis_re_tuser;
    pdcch_packer_minimal dut (
        .aclk(aclk), .aresetn(aresetn),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_aggregation_level(cfg_aggregation_level),
        .s_axis_data_tdata(s_axis_data_tdata),
        .s_axis_data_tvalid(s_axis_data_tvalid),
        .s_axis_data_tready(s_axis_data_tready),
        .s_axis_data_tlast(s_axis_data_tlast),
        .s_axis_dmrs_tdata(s_axis_dmrs_tdata),
        .s_axis_dmrs_tvalid(s_axis_dmrs_tvalid),
        .s_axis_dmrs_tready(s_axis_dmrs_tready),
        .s_axis_dmrs_tlast(s_axis_dmrs_tlast),
        .m_axis_re_tdata(m_axis_re_tdata),
        .m_axis_re_tvalid(m_axis_re_tvalid),
        .m_axis_re_tready(m_axis_re_tready),
        .m_axis_re_tlast(m_axis_re_tlast),
        .m_axis_re_tuser(m_axis_re_tuser)
    );
    integer passed = 0, total_checked = 0;
    integer nd, nm, no, cycles, re_pos, reg_pos, last_hold;
    integer stalls, dgaps, mgaps;
    reg df, mf, ofire, is_dmrs, held;
    reg [31:0] held_data, expected_data;
    reg [11:0] held_user, expected_user;
    reg held_last;

    task reset_dut;
        begin
            aresetn = 0; cfg_valid = 0;
            s_axis_data_tvalid = 0; s_axis_dmrs_tvalid = 0;
            s_axis_data_tlast = 0; s_axis_dmrs_tlast = 0;
            m_axis_re_tready = 0;
            repeat (3) @(posedge aclk);
            #1;
            if (cfg_ready !== 1 || m_axis_re_tvalid !== 0 ||
                s_axis_data_tready !== 0 || s_axis_dmrs_tready !== 0)
                $fatal(1, "FAIL: reset khong ve IDLE");
            aresetn = 1;
        end
    endtask

    task run_packet;
        input integer al;
        input stress;
        input omit_last;
        begin
            $display("BAT DAU: AL=%0d stress=%0d omit_last=%0d", al,stress,omit_last);
            if (cfg_ready !== 1) $fatal(1, "FAIL: DUT chua san sang");
            cfg_aggregation_level = al[4:0]; cfg_valid = 1;
            @(posedge aclk);
            #1 cfg_valid = 0;
            nd=0; nm=0; no=0; cycles=0; re_pos=0; reg_pos=0;
            held=0; last_hold=0; stalls=0; dgaps=0; mgaps=0;
            while (no < 72*al && cycles < 30000) begin
                // Chi thay mau khi VALID da ha sau handshake.
                if (!s_axis_data_tvalid && nd < 54*al) begin
                    s_axis_data_tvalid = !stress || cycles[1:0] != 0;
                    s_axis_data_tdata = 32'h10000000 + nd[31:0];
                    s_axis_data_tlast = !omit_last && nd == 54*al-1;
                end
                if (!s_axis_dmrs_tvalid && nm < 18*al) begin
                    s_axis_dmrs_tvalid = !stress || cycles[2:0] == 3;
                    s_axis_dmrs_tdata = 32'hD0000000 + nm[31:0];
                    s_axis_dmrs_tlast = !omit_last && nm == 18*al-1;
                end
                m_axis_re_tready = !stress || cycles[2:0] >= 3;
                if (stress && no == 72*al-1 && last_hold < 3) begin
                    m_axis_re_tready = 0; last_hold = last_hold + 1;
                end
                @(posedge aclk);
                is_dmrs = re_pos == 1 || re_pos == 5 || re_pos == 9;
                expected_user = {is_dmrs, re_pos[3:0], reg_pos[6:0]};
                expected_data = is_dmrs ? 32'hD0000000+nm[31:0] : 32'h10000000+nd[31:0];
                if (cfg_ready !== 0) $fatal(1, "FAIL: cfg_ready trong PACK");
                if (s_axis_data_tready !== (!is_dmrs && m_axis_re_tready) ||
                    s_axis_dmrs_tready !== (is_dmrs && m_axis_re_tready))
                    $fatal(1, "FAIL: READY sai nguon, RE=%0d", no);
                if (m_axis_re_tvalid !== (is_dmrs ? s_axis_dmrs_tvalid : s_axis_data_tvalid))
                    $fatal(1, "FAIL: VALID sai nguon");
                if (held && (m_axis_re_tvalid !== 1 ||
                    m_axis_re_tdata !== held_data || m_axis_re_tuser !== held_user ||
                    m_axis_re_tlast !== held_last))
                    $fatal(1, "FAIL: output thay doi khi stall");
                if (m_axis_re_tvalid) begin
                    if (m_axis_re_tdata !== expected_data ||
                        m_axis_re_tuser !== expected_user ||
                        m_axis_re_tlast !== (no == 72*al-1))
                        $fatal(1, "FAIL AL=%0d RE=%0d data=%h expected=%h user=%h expected=%h last=%b",
                            al,no,m_axis_re_tdata,expected_data,m_axis_re_tuser,expected_user,m_axis_re_tlast);
                end
                held = m_axis_re_tvalid && !m_axis_re_tready;
                held_data=m_axis_re_tdata; held_user=m_axis_re_tuser; held_last=m_axis_re_tlast;
                if (held) stalls=stalls+1;
                if (!is_dmrs && !s_axis_data_tvalid) dgaps=dgaps+1;
                if (is_dmrs && !s_axis_dmrs_tvalid) mgaps=mgaps+1;
                df=s_axis_data_tvalid && s_axis_data_tready;
                mf=s_axis_dmrs_tvalid && s_axis_dmrs_tready;
                ofire=m_axis_re_tvalid && m_axis_re_tready;
                if (ofire !== (df || mf) || (df && mf))
                    $fatal(1, "FAIL: handshake khong bao toan mau");
                if (df) nd=nd+1;
                if (mf) nm=nm+1;
                if (ofire) begin
                    no=no+1;
                    if (re_pos == 11) begin re_pos=0; reg_pos=reg_pos+1; end
                    else re_pos=re_pos+1;
                end
                cycles=cycles+1;
                #1;
                if (df) s_axis_data_tvalid=0;
                if (mf) s_axis_dmrs_tvalid=0;
            end
            if (no != 72*al || nd != 54*al || nm != 18*al)
                $fatal(1, "FAIL: timeout/count DATA=%0d DMRS=%0d OUT=%0d",nd,nm,no);
            if (stress && (stalls == 0 || dgaps == 0 || mgaps == 0 || last_hold != 3))
                $fatal(1, "FAIL: chua tao du stall/gap");
            if (cfg_ready !== 1 || m_axis_re_tvalid !== 0 || m_axis_re_tlast !== 0)
                $fatal(1, "FAIL: ket thuc goi");
            m_axis_re_tready=0;
            total_checked=total_checked+no; passed=passed+1;
            $display("PASS: DATA=%0d DMRS=%0d OUT=%0d cycles=%0d stalls=%0d",nd,nm,no,cycles,stalls);
        end
    endtask

    task invalid_al;
        input [4:0] al;
        begin
            cfg_aggregation_level=al; cfg_valid=1;
            @(posedge aclk);
            #1 cfg_valid=0;
            if (cfg_ready !== 1 || m_axis_re_tvalid !== 0)
                $fatal(1, "FAIL: chap nhan AL sai %0d",al);
            passed=passed+1;
            $display("PASS: bo qua AL=%0d",al);
        end
    endtask

    initial begin
        $display("===== BAT DAU TEST PDCCH PACKER =====");
        if ($test$plusargs("DUMP")) begin
            $dumpfile("tb_pdcch_packer.vcd");
            $dumpvars(0,tb_pdcch_packer);
        end
        @(posedge aclk);
        #1;
        reset_dut;
        run_packet(1,0,0); run_packet(2,0,0); run_packet(4,0,0);
        run_packet(8,0,0); run_packet(16,0,0);
        run_packet(1,1,0); run_packet(2,1,0); run_packet(4,1,0);
        run_packet(8,1,0); run_packet(16,1,0);
        // DUT hien tai bo qua TLAST dau vao; ket thuc theo AL.
        run_packet(1,1,1);
        invalid_al(0); invalid_al(3); invalid_al(31);
        // Reset sau khi truyen DATA dau tien, dang doi DMRS.
        cfg_aggregation_level=1; cfg_valid=1;
        @(posedge aclk);
        #1 cfg_valid=0;
        s_axis_data_tdata=32'h12345678;
        s_axis_data_tvalid=1; m_axis_re_tready=1;
        @(posedge aclk);
        if (!(s_axis_data_tready && m_axis_re_tvalid))
            $fatal(1, "FAIL: chua tao duoc goi dang do");
        #1;
        reset_dut;
        passed=passed+1;
        $display("PASS: reset giua goi");
        run_packet(2,1,0);
        repeat (5) begin
            @(posedge aclk);
            #1;
            if (m_axis_re_tvalid !== 0 || cfg_ready !== 1)
                $fatal(1, "FAIL: output thua sau goi");
        end
        $display("===== KET THUC: PASS %0d TEST, %0d RE DA KIEM TRA =====",passed,total_checked);
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1, "FAIL: GLOBAL TIMEOUT");
    end
endmodule
