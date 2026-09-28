# PDCCH packer: giao tiếp và kiểm thử

## Chức năng và phạm vi

`pdcch_packer.v`, module **pdcch_packer_minimal**, ghép DATA QPSK và DMRS
thành các REG logic. Tên module và danh sách cổng giữ như bản cũ.
Mỗi mẫu giữ nguyên 32 bit: `[31:16]=Q`, `[15:0]=I`.

Một gói AL CCE có `6*AL` REG, nhận `54*AL` mẫu DATA và `18*AL` mẫu DMRS,
phát `72*AL` mẫu. Trong mỗi REG, vị trí RE 1, 5, 9 lấy từ nguồn DMRS;
các vị trí còn lại lấy từ DATA. Chỉ nguồn đang được chọn mới có TREADY.

Packer không làm interleaving, không tạo DMRS, không ghi RAM, không sinh địa
chỉ Resource Grid. Hai nguồn phải được sắp xếp theo hợp đồng REG logic của
hệ thống. Đặc biệt, không được đưa nguyên luồng DMRS toàn CORESET vào đây nếu
chưa chọn và sắp xếp đúng các mẫu cho những REG được cấp phát. Testbench xác
minh việc ghép hai luồng đã chuẩn bị đúng, không chứng minh toàn chuỗi PDCCH
với interleaver/DMRS generator/RAM đã tích hợp đúng 3GPP.

## Cấu hình và bắt đầu/kết thúc

| Tín hiệu | Ý nghĩa |
|---|---|
| `aclk` | Clock; tất cả thanh ghi cập nhật ở sườn dương |
| `aresetn` | Reset đồng bộ mức thấp, hủy gói và mẫu còn đệm |
| `cfg_valid && cfg_ready` | Nhận cấu hình mới |
| `cfg_aggregation_level[4:0]` | AL thực: 1, 2, 4, 8, 16; khác mã AL 0..4 của mapper |
| `s_axis_data_*` | Luồng DATA, đúng 54*AL mẫu |
| `s_axis_dmrs_*` | Luồng DMRS, đúng 18*AL mẫu |
| `m_axis_re_*` | Luồng REG logic, đúng 72*AL mẫu |
| `m_axis_re_tuser[11]` | 1=DMRS, 0=DATA |
| `m_axis_re_tuser[10:7]` | RE trong REG: 0..11 |
| `m_axis_re_tuser[6:0]` | REG tương đối trong PDCCH: 0..6*AL-1 |
| `m_axis_re_tlast` | Gắn với RE 11 của REG cuối |

Gói chỉ hoàn thành tại cạnh có `m_axis_re_tvalid && m_axis_re_tready &&
m_axis_re_tlast`. `cfg_ready` giữ thấp tới lúc đó; cấu hình mới sớm nhất
được nhận ở cạnh tiếp theo. Không cần thêm chân start/done.

Mọi nguồn phải giữ valid và payload khi valid=1, ready=0. Reset làm mất
hiệu lực gói hiện tại; bên ngoài phải reset/khởi động lại các nguồn tương ứng.
Các handshake được chặn khi reset đang thấp; trạng thái nội bộ chỉ reset ở
posedge. Nhả reset đồng bộ với clock trong hệ thống thực.

## Bộ đệm và thay đổi so với bản cũ

- Thêm một thanh ghi đầu ra chứa DATA, USER, LAST và VALID.
- Độ trễ tối thiểu từ input handshake đến output handshake là 1 chu kỳ.
- Khi nguồn liên tục và downstream sẵn sàng: một mẫu mỗi chu kỳ sau khi nạp
  tầng đệm; đồng thời lấy output cũ và nạp input mới.
- Khi downstream dừng và đệm rỗng, có thể nhận trước đúng một mẫu.
- Bộ đếm REG/RE tăng theo **input handshake**, vì payload đã được chốt.
- ST_DRAIN ngừng nhận nguồn sau mẫu cuối và chờ output cuối được nhận.
- Bỏ bộ đếm tổng mẫu đầu ra, dùng `last_reg`, `reg_index`, `re_index`.
- Không có phép chia lấy dư, không có function trong RTL.
- DATA/USER/LAST/VALID được giữ khi stall. TREADY vẫn có đường tổ hợp từ
  downstream; nếu cần cắt đường timing này, dùng AXIS register slice.

## Gói lỗi và giới hạn tương thích

Giữ giao diện cũ đồng nghĩa **không có cổng báo lỗi**:

- 27 mã AL khác 1/2/4/8/16: handshake cấu hình rồi bỏ, không nhận mẫu và không
  phát gói. Parser phải kiểm tra cấu hình nếu cần báo lỗi.
- `s_axis_*_tlast` không điều khiển/cắt gói; AL quyết định số mẫu. TLAST sớm,
  muộn, luôn 1 hoặc thiếu đều không đổi kết quả nếu số mẫu vẫn đủ.
- Nguồn thiếu mẫu: chờ, không tự timeout hay tự hoàn thành. Reset để hủy gói.
- Nguồn thừa: không nhận quá số mẫu của gói; mẫu còn chờ phải được quản lý
  ở upstream. Nếu gửi cấu hình tiếp khi upstream còn mẫu thừa, mẫu đó sẽ bị
  hiểu là dữ liệu gói tiếp. Packer không tự tìm lại biên gói lỗi.

Muốn phát hiện/phục hồi gói sai TLAST trong phần cứng cần thiết kế giao thức
báo lỗi và đồng bộ lại cả hai nguồn; bản tương thích này không tuyên bố có
chức năng đó.

## Testbench tự kiểm tra

Top: **tb_pdcch_packer** trong `tb_pdcch_packer.v`.
Testbench drive tín hiệu sau posedge 1 ns và kiểm tra handshake tại posedge,
tránh race với cập nhật nonblocking của DUT. Không dùng negedge.

| Nhóm | Kiểm tra |
|---|---|
| AL | Tất cả 5 AL hợp lệ và 27 mã sai |
| Ghép mẫu | Đúng nguồn, thứ tự, không mất/lặp, đúng 54*AL và 18*AL |
| Metadata | So từng TUSER và TLAST của mọi beat |
| Thông lượng | Liên tục đạt một mẫu/clock sau latency 1 clock |
| Backpressure | Ngẫu nhiên; chặn 20 chu kỳ tại beat đầu/cuối; giữ output ổn định |
| Nguồn trễ | DATA và DMRS bị trễ độc lập; random valid giữ đúng khi stall |
| Cấu hình | Không nhận khi bận; giữ yêu cầu AL=2 chờ gói trước kết thúc |
| Input thừa | Một mẫu thừa mỗi nguồn không được nhận khi chưa có config tiếp |
| Input TLAST | Đúng, thiếu, luôn 1; xác minh chính sách đếm theo AL |
| Reset | Idle; từng vị trí REG đầu; gần cuối AL=16; stall DATA, DMRS, beat cuối |
| Phục hồi | Gửi lại gói đầy đủ sau mỗi reset hủy gói |
| Timeout | Giới hạn vòng chờ và watchdog toàn testbench |

Mỗi lần chạy có 70 kịch bản gói (một kịch bản gồm hai gói liền nhau),
27 cấu hình sai; 55 gói hoàn thành và 16 gói bị reset có chủ đích.
Không gọi đây là kiểm thử vét cạn mọi chuỗi tín hiệu hoặc formal verification.

## Chạy mô phỏng

Vivado: thêm RTL vào Design Sources, TB vào Simulation Sources, đặt
`tb_pdcch_packer` làm Simulation Top, chạy **Run All**. Thành công phải có
`ALL PASS`; `$fatal` hoặc timeout là thất bại. Không chỉ dựa vào việc có waveform.

Icarus Verilog:

```sh
iverilog -g2012 -s tb_pdcch_packer -o sim_packer pdcch_packer.v tb_pdcch_packer.v
vvp sim_packer
vvp sim_packer +SEED=42
```

Chạy nhiều seed, tự chọn Icarus hoặc Verilator:

```sh
bash scripts/run_pdcch_tests.sh
```

Đã kiểm chứng bằng Verilator với seed mặc định và 10 seed bổ sung.
Chưa chạy Vivado synthesis/implementation, chưa có kết quả LUT/FF/Fmax
hay timing closure trên FPGA đích. Bản testbench CCE mapper sẵn có chạy tới `$finish` nhưng kết thúc khi mapper
vẫn ở state=3 và chưa so sánh bitmap; không tính lần chạy đó là chứng nhận
mapper PASS. Đây cũng không phải integration test với packer.
