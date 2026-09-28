`timescale 1ns/1ps
// Testbench tự kiểm tra. Drive sau posedge 1 ns, sample trước NBA:
// DUT và testbench đều dùng sườn dương, không tranh chấp tín hiệu.
module tb_pdcch_packer;
    reg aclk = 0;
    always #5 aclk = ~aclk;
    reg aresetn = 0;
    reg cfg_valid = 0;
    reg [4:0] cfg_aggregation_level = 0;
    wire cfg_ready;
    reg [31:0] s_axis_data_tdata = 0, s_axis_dmrs_tdata = 0;
    reg s_axis_data_tvalid = 0, s_axis_dmrs_tvalid = 0;
    reg s_axis_data_tlast = 0, s_axis_dmrs_tlast = 0;
    wire s_axis_data_tready, s_axis_dmrs_tready;
    wire [31:0] m_axis_re_tdata;
    wire [11:0] m_axis_re_tuser;
    wire m_axis_re_tvalid, m_axis_re_tlast;
    reg m_axis_re_tready = 0;
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

    // Scoreboard độc lập: từng REG có 12 mẫu, DMRS ở 1,5,9.
    reg [31:0] expected_data [0:1151];
    reg [11:0] expected_user [0:1151];
    integer data_in = 0, dmrs_in = 0, outputs = 0;
    integer total = 0, al_current = 0, completed = 0, tests = 0;
    integer cycle_count = 0;
    reg active = 0, stalled = 0;
    reg [44:0] held_output;
    reg data_fire, dmrs_fire, cfg_fire;
    reg [31:0] rng = 32'h7351abcd;
    integer seed_arg;

    // Mỗi lần tick quan sát đúng giao dịch ở sườn dương.
    task tick;
    begin
        @(posedge aclk);
        cycle_count = cycle_count + 1;
        data_fire = s_axis_data_tvalid && s_axis_data_tready;
        dmrs_fire = s_axis_dmrs_tvalid && s_axis_dmrs_tready;
        cfg_fire = cfg_valid && cfg_ready;
        if (!aresetn) begin
            if (cfg_ready || s_axis_data_tready || s_axis_dmrs_tready || m_axis_re_tvalid)
                $fatal(1, "Handshake phai tat khi reset");
            active = 0;
            stalled = 0;
        end else begin
            if (stalled && (!m_axis_re_tvalid ||
                {m_axis_re_tdata,m_axis_re_tlast,m_axis_re_tuser} !== held_output))
                $fatal(1, "Output thay doi khi bi backpressure");
            if (!active && (data_fire || dmrs_fire))
                $fatal(1, "Nhan input khi chua co goi");
            if (s_axis_data_tready && s_axis_dmrs_tready)
                $fatal(1, "Khong duoc nhan hai nguon cung luc");
            if (active && cfg_ready)
                $fatal(1, "Nhan config moi khi goi cu chua xong");
            if (data_fire) data_in = data_in + 1;
            if (dmrs_fire) dmrs_in = dmrs_in + 1;
            if (m_axis_re_tvalid && m_axis_re_tready) begin
                if (!active || outputs >= total) $fatal(1, "Output thua/khong co config");
                if (m_axis_re_tdata !== expected_data[outputs] ||
                    m_axis_re_tuser !== expected_user[outputs] ||
                    m_axis_re_tlast !== (outputs == total-1))
                    $fatal(1, "Sai beat %0d: data=%h user=%h last=%b", outputs,
                           m_axis_re_tdata,m_axis_re_tuser,m_axis_re_tlast);
                // Không được phát dữ liệu chưa từng nhận từ nguồn.
                if (data_in + dmrs_in < outputs+1) $fatal(1, "Output truoc input");
                outputs = outputs + 1;
                if (outputs == total) begin
                    if (data_in != 54*al_current || dmrs_in != 18*al_current)
                        $fatal(1, "Sai so mau input");
                    active = 0;
                    completed = completed + 1;
                end
            end
            if (cfg_fire && (cfg_aggregation_level==1 || cfg_aggregation_level==2 ||
                cfg_aggregation_level==4 || cfg_aggregation_level==8 || cfg_aggregation_level==16))
                active = 1;
            stalled = m_axis_re_tvalid && !m_axis_re_tready;
            held_output = {m_axis_re_tdata,m_axis_re_tlast,m_axis_re_tuser};
        end
        #1;
        // PRNG xác định, không dùng phép chia lấy dư.
        rng = rng ^ (rng << 13);
        rng = rng ^ (rng >> 17);
        rng = rng ^ (rng << 5);
    end
    endtask

    task reset_dut;
    begin
        aresetn = 0;
        cfg_valid = 0;
        s_axis_data_tvalid = 0;
        s_axis_dmrs_tvalid = 0;
        m_axis_re_tready = 0;
        repeat (3) tick;
        aresetn = 1;
        tick;
        if (!cfg_ready || m_axis_re_tvalid) $fatal(1, "Reset khong ve idle");
    end
    endtask

    // Mẫu có dấu nhận diện nguồn và thứ tự để phát hiện tráo/mất/lặp mẫu.
    task prepare;
        input integer al;
        integer r,k,n,d,m;
    begin
        al_current=al; total=72*al; data_in=0; dmrs_in=0; outputs=0;
        d=0; m=0; n=0;
        for (r=0;r<6*al;r=r+1)
            for (k=0;k<12;k=k+1) begin
                if (k==1 || k==5 || k==9) begin
                    expected_data[n]=32'hd0000000+m;
                    expected_user[n]={1'b1,k[3:0],r[6:0]}; m=m+1;
                end else begin
                    expected_data[n]=32'ha0000000+d;
                    expected_user[n]={1'b0,k[3:0],r[6:0]}; d=d+1;
                end
                n=n+1;
            end
    end
    endtask

    // mode: 0 liên tục; 1 ngẫu nhiên; 2 chặn beat đầu;
    // 3 chặn beat cuối; 4 nguồn DATA đến chậm; 5 nguồn DMRS đến chậm.
    // mode 6: nguồn thừa một mẫu; 7/8/9: reset khi stall DATA/DMRS/beat cuối.
    // mode 10: giữ config AL=2 trong lúc bận, nhận ngay khi gói cũ kết thúc.
    // last_mode: 0 đúng; 1 thiếu TLAST; 2 TLAST luôn 1 (cố ý sai).
    // abort_at: -1 chạy đủ; >=0 reset khi đã phát số beat này.
    task run_packet;
        input integer al, mode, last_mode, abort_at;
        integer cycles, hold_cycles, before_done;
    begin
        tests=tests+1;
        $display("START test=%0d AL=%0d mode=%0d last=%0d abort=%0d",tests,al,mode,last_mode,abort_at);
        prepare(al);
        cfg_aggregation_level=al[4:0]; cfg_valid=1;
        tick;
        if (!cfg_fire) $fatal(1,"Config khong duoc nhan");
        cfg_valid=0;
        cycles=0; hold_cycles=0; before_done=completed;
        begin : packet_loop
        while (completed==before_done) begin
            // Chỉ đổi mẫu sau handshake; giữ valid/data/last khi nguồn bị chặn.
            if (!s_axis_data_tvalid || data_fire) begin
                s_axis_data_tvalid=(data_in<54*al+((mode==6)?1:0)) &&
                    ((mode!=1) || rng[0]) && ((mode!=4) || cycles>30);
                s_axis_data_tdata=32'ha0000000+data_in;
                s_axis_data_tlast=(last_mode==2) || ((last_mode==0) && data_in==54*al-1);
            end
            if (!s_axis_dmrs_tvalid || dmrs_fire) begin
                s_axis_dmrs_tvalid=(dmrs_in<18*al+((mode==6)?1:0)) &&
                    ((mode!=1) || rng[4]) && ((mode!=5) || cycles>30);
                s_axis_dmrs_tdata=32'hd0000000+dmrs_in;
                s_axis_dmrs_tlast=(last_mode==2) || ((last_mode==0) && dmrs_in==18*al-1);
            end
            m_axis_re_tready=(mode!=1) || rng[9];
            if ((mode==2 && outputs==0) || (mode==3 && outputs==total-1)) begin
                if (hold_cycles<20) begin
                    m_axis_re_tready=0; hold_cycles=hold_cycles+1;
                end
            end
            if ((mode==7 && outputs==0) || (mode==8 && outputs==1) ||
                (mode==9 && outputs==total-1)) begin
                m_axis_re_tready=0;
                hold_cycles=hold_cycles+1;
            end
            // Một yêu cầu config sai chỉ đưa khi đang bận, không được nhận.
            cfg_valid=(cycles>=5 && ((mode==10) || cycles<10));
            cfg_aggregation_level=(mode==10) ? 5'd2 : 5'd0;
            tick;
            cycles=cycles+1;
            if (cfg_fire) $fatal(1,"Config bi nhan giua goi");
            if (mode==2 && cycles==10 && data_in+dmrs_in!=1)
                $fatal(1,"Output register phai giu dung mot mau khi ready=0");
            if ((abort_at>=0 && outputs>=abort_at) ||
                (mode>=7 && mode<=9 && hold_cycles>=5)) begin
                reset_dut;
                disable packet_loop;
            end
            if (cycles>20000) $fatal(1,"TIMEOUT packet");
        end
        end
        if (mode==10) begin
            // Cấu hình AL=2 đã giữ ổn định khi busy, handshake ngay cạnh tới.
            s_axis_data_tvalid=0; s_axis_dmrs_tvalid=0;
            prepare(2);
            tick;
            if (!cfg_fire) $fatal(1,"Config cho san khong duoc nhan");
            cfg_valid=0;
            cycles=0;
            while (active) begin
                if (!s_axis_data_tvalid || data_fire) begin
                    s_axis_data_tvalid=(data_in<108);
                    s_axis_data_tdata=32'ha0000000+data_in;
                    s_axis_data_tlast=(data_in==107);
                end
                if (!s_axis_dmrs_tvalid || dmrs_fire) begin
                    s_axis_dmrs_tvalid=(dmrs_in<36);
                    s_axis_dmrs_tdata=32'hd0000000+dmrs_in;
                    s_axis_dmrs_tlast=(dmrs_in==35);
                end
                m_axis_re_tready=1;
                tick;
                cycles=cycles+1;
                if (cycles>2000) $fatal(1,"TIMEOUT goi lien tiep");
            end
        end
        cfg_valid=0;
        if (mode==6) begin
            // Hai mẫu thừa đang chờ không được nhận khi gói đã kết thúc.
            s_axis_data_tvalid=1; s_axis_dmrs_tvalid=1;
            repeat (5) tick;
        end
        s_axis_data_tvalid=0; s_axis_dmrs_tvalid=0;
        if (abort_at<0 && (mode<7 || mode==10)) begin
            repeat (3) tick;
            if (!cfg_ready || m_axis_re_tvalid) $fatal(1,"Khong ket thuc sach");
        end
        if (mode==0 && abort_at<0 && cycles!=total+1)
            $fatal(1,"Luồng liên tục phải đạt một mẫu/clock sau latency 1 clock");
        $display("PASS test=%0d outputs=%0d cycles=%0d",tests,outputs,cycles);
    end
    endtask

    integer a,mode,i;
    initial begin
        if ($value$plusargs("SEED=%d",seed_arg)) rng=seed_arg;
        if (rng==0) rng=1;
        #1;
        reset_dut;
        // Toàn bộ 27 mã AL không hợp lệ phải bị bỏ, không đọc input.
        for (i=0;i<32;i=i+1) begin
            if (i!=1 && i!=2 && i!=4 && i!=8 && i!=16) begin
                cfg_aggregation_level=i[4:0]; cfg_valid=1;
                s_axis_data_tvalid=1; s_axis_dmrs_tvalid=1;
                m_axis_re_tready=1;
                tick;
                if (!cfg_fire || data_fire || dmrs_fire) $fatal(1,"AL sai van nhan data");
                cfg_valid=0;
                tick;
                if (!cfg_ready || m_axis_re_tvalid) $fatal(1,"AL sai van phat output");
            end
        end
        s_axis_data_tvalid=0; s_axis_dmrs_tvalid=0;
        for (a=1;a<=16;a=a*2)
            for (mode=0;mode<7;mode=mode+1) run_packet(a,mode,0,-1);
        run_packet(1,10,0,-1);
        run_packet(1,1,1,-1);
        run_packet(2,1,2,-1);
        // Reset tại từng vị trí trong REG đầu và gần cuối gói; luôn có gói phục hồi.
        for (i=0;i<12;i=i+1) begin
            run_packet(1,0,0,i);
            run_packet(1,1,0,-1);
        end
        for (mode=7;mode<=9;mode=mode+1) begin
            run_packet(1,mode,0,-1);
            run_packet(1,0,0,-1);
        end
        run_packet(16,0,0,1151);
        run_packet(16,1,0,-1);
        $display("ALL PASS: %0d packet scenarios, 27 invalid AL, completed=%0d cycles=%0d",tests,completed,cycle_count);
        $finish;
    end
    initial begin
        #10000000;
        $fatal(1,"TIMEOUT toan bo testbench");
    end
endmodule
