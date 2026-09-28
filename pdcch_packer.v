`timescale 1ns / 1ps
`default_nettype none
// Packer DATA/DMRS thành luồng REG logic, chưa thực hiện CCE-to-REG interleaving.
// Một cấu hình: AL CCE, 6*AL REG, mỗi REG gồm 9 DATA và 3 DMRS.
// Mỗi mẫu 32 bit giữ nguyên [31:16]=Q, [15:0]=I.
// Bắt đầu: cfg_valid && cfg_ready tại posedge aclk.
// Kết thúc: m_axis_re_tvalid && m_axis_re_tready && m_axis_re_tlast.
// Reset đồng bộ mức thấp: hủy gói đang xử lý, kể cả beat còn trong output.
//
// HỢP ĐỒNG NGUỒN:
// - AL là giá trị thực 1/2/4/8/16, KHÔNG phải mã AL của CCE mapper.
// - DATA: đúng 54*AL mẫu; DMRS: đúng 18*AL mẫu, theo thứ tự REG logic.
// - DMRS phải được chọn/sắp xếp cho các REG cần dùng từ trước;
//   khối này không chọn DMRS theo địa chỉ CORESET vật lý.
// - Nguồn giữ TVALID/TDATA/TLAST khi TVALID=1 và TREADY=0.
// - TLAST đầu vào được giữ để tương thích giao diện nhưng KHÔNG điều khiển
//   độ dài. Không có cổng báo lỗi gói. Nguồn thiếu dữ liệu: chờ đến khi có
//   tiếp hoặc reset. Nguồn thừa: không nhận vượt số mẫu của cấu hình.
// - Sau reset, bên ngoài phải khởi động lại cả cấu hình và hai luồng nguồn.
module pdcch_packer_minimal (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        cfg_valid,
    output wire        cfg_ready,
    input  wire [4:0]  cfg_aggregation_level,

    input  wire [31:0] s_axis_data_tdata,
    input  wire        s_axis_data_tvalid,
    output wire        s_axis_data_tready,
    input  wire        s_axis_data_tlast,

    input  wire [31:0] s_axis_dmrs_tdata,
    input  wire        s_axis_dmrs_tvalid,
    output wire        s_axis_dmrs_tready,
    input  wire        s_axis_dmrs_tlast,

    output reg  [31:0] m_axis_re_tdata,
    output wire        m_axis_re_tvalid,
    input  wire        m_axis_re_tready,
    output reg         m_axis_re_tlast,
    output reg  [11:0] m_axis_re_tuser
);
    localparam [1:0] ST_IDLE  = 2'd0; // Chờ cấu hình; AL sai được nhận rồi bỏ.
    localparam [1:0] ST_PACK  = 2'd1; // Ghép và chốt các mẫu vào thanh ghi output.
    localparam [1:0] ST_DRAIN = 2'd2; // Đã nhận mẫu cuối, chờ output cuối được nhận.
    reg [1:0] state;
    reg [6:0] last_reg;  // REG cuối của gói: 6*AL-1, tối đa 95.
    reg [6:0] reg_index; // REG của mẫu ĐẦU VÀO sẽ nhận tiếp, từ 0 đến last_reg.
    reg [3:0] re_index;  // Vị trí mẫu trong REG, từ 0 đến 11.
    reg out_valid;      // Thanh ghi output đang chứa một mẫu hợp lệ.

    wire select_dmrs;   // 1: lấy nguồn DMRS; 0: lấy nguồn DATA.
    wire output_space;  // Output rỗng hoặc beat cũ sẽ được nhận tại cạnh này.
    wire input_fire;    // Một mẫu của nguồn được chọn được nhận tại cạnh này.
    wire final_input;   // Mẫu đang nhận là RE 11 của REG cuối.

    // Không công bố handshake khi reset. Các thanh ghi vẫn chỉ đổi ở posedge.
    assign cfg_ready = aresetn && (state == ST_IDLE);
    assign m_axis_re_tvalid = aresetn && out_valid;
    assign output_space = !out_valid || m_axis_re_tready;
    assign select_dmrs = (re_index == 4'd1) ||
                         (re_index == 4'd5) || (re_index == 4'd9);
    assign s_axis_data_tready = aresetn && (state == ST_PACK) &&
                               output_space && !select_dmrs;
    assign s_axis_dmrs_tready = aresetn && (state == ST_PACK) &&
                               output_space && select_dmrs;
    assign input_fire = (s_axis_data_tvalid && s_axis_data_tready) ||
                        (s_axis_dmrs_tvalid && s_axis_dmrs_tready);
    assign final_input = (reg_index == last_reg) && (re_index == 4'd11);

    // TUSER giữ định dạng cũ: [11]=DMRS, [10:7]=RE, [6:0]=REG logic.
    // Output có một tầng register, trễ tối thiểu 1 clock từ input handshake.
    // Có thể đồng thời tiêu thụ output cũ và nạp mẫu mới: tối đa 1 mẫu/clock.
    // TREADY còn đường tổ hợp từ downstream; đây không phải AXIS register slice
    // cách ly hoàn toàn đường ready. Nếu cần timing isolation, thêm register slice.
    always @(posedge aclk) begin
        if (!aresetn) begin
            state            <= ST_IDLE;
            last_reg         <= 7'd0;
            reg_index        <= 7'd0;
            re_index         <= 4'd0;
            out_valid        <= 1'b0;
            m_axis_re_tdata  <= 32'd0;
            m_axis_re_tlast  <= 1'b0;
            m_axis_re_tuser  <= 12'd0;
        end else begin
            // Nếu chỉ đọc mà không nạp mới, output trở thành rỗng.
            // Khi bị stall, không nhánh nào thay đổi payload hoặc valid.
            if (out_valid && m_axis_re_tready) begin
                out_valid       <= 1'b0;
                m_axis_re_tlast <= 1'b0;
            end
            case (state)
                ST_IDLE: begin
                    if (cfg_valid && cfg_ready) begin
                        reg_index <= 7'd0;
                        re_index  <= 4'd0;
                        case (cfg_aggregation_level)
                            5'd1:  begin last_reg <= 7'd5;  state <= ST_PACK; end
                            5'd2:  begin last_reg <= 7'd11; state <= ST_PACK; end
                            5'd4:  begin last_reg <= 7'd23; state <= ST_PACK; end
                            5'd8:  begin last_reg <= 7'd47; state <= ST_PACK; end
                            5'd16: begin last_reg <= 7'd95; state <= ST_PACK; end
                            default: begin last_reg <= 7'd0; state <= ST_IDLE; end
                        endcase
                    end
                end
                ST_PACK: begin
                    if (input_fire) begin
                        m_axis_re_tdata <= select_dmrs ? s_axis_dmrs_tdata : s_axis_data_tdata;
                        m_axis_re_tuser <= {select_dmrs, re_index, reg_index};
                        m_axis_re_tlast <= final_input;
                        out_valid       <= 1'b1;
                        if (final_input) begin
                            // Ngừng nhận nguồn ngay, nhưng chưa nhận cấu hình mới.
                            state <= ST_DRAIN;
                        end else if (re_index == 4'd11) begin
                            re_index  <= 4'd0;
                            reg_index <= reg_index + 7'd1;
                        end else begin
                            re_index <= re_index + 4'd1;
                        end
                    end
                end
                ST_DRAIN: begin
                    if (out_valid && m_axis_re_tready) state <= ST_IDLE;
                end
                default: begin
                    state            <= ST_IDLE;
                    out_valid        <= 1'b0;
                    m_axis_re_tlast  <= 1'b0;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
