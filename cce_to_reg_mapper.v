`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/21/2026 09:47:00 AM
// Design Name: 
// Module Name: cce_to_reg_mapper
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

// 1 REG = 1 RB * 1 Symbol // 12 RE
// 1 CE = 6 REG // 72 RE
// CCE chiem full duration cua CORESET
// REG bundle size : L
// Interleaver size : R

module cce_to_reg_mapper #(
    parameter integer MAX_RB = 108
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // Giao dien cau hinh dau vao.
    input  wire [63:0]                s_axis_cfg_tdata,
    input  wire                       s_axis_cfg_tvalid,
    output wire                       s_axis_cfg_tready,

    // Bitmap PDCCH dau ra.
    output reg  [(MAX_RB*14)-1:0]     pdcch_rb_bitmap,
    output reg                        pdcch_rb_bitmap_valid,
    input  wire                       pdcch_rb_bitmap_ready
);

    localparam integer BITMAP_WIDTH = MAX_RB * 14;
    localparam [9:0]   MAX_RB_VALUE = MAX_RB[9:0];
    localparam [15:0]  BITMAP_LIMIT = BITMAP_WIDTH[15:0];
    localparam integer BITMAP_INDEX_WIDTH = $clog2(BITMAP_WIDTH);

    // -------------------------------------------------------------------------
    // Cac truong cau hinh duoc chot khi input handshake thanh cong.
    // -------------------------------------------------------------------------
    reg [7:0] cfg_cce_start;          // TDATA[7:0]: CCE dau tien
    reg [2:0] cfg_al;                 // TDATA[10:8]: 0..4 -> AL 1..16
    reg [2:0] cfg_bundle_size;        // TDATA[13:11]: L bang 2, 3 hoac 6
    reg       cfg_interleaver_mode;   // TDATA[14]: 1 la interleaved
    reg [2:0] cfg_interleaver_size;   // TDATA[17:15]: R bang 2, 3 hoac 6
    reg [9:0] cfg_rb_number;          // TDATA[27:18]: so RB cua CORESET
    reg [8:0] cfg_shift_index;        // TDATA[36:28]: n_shift
    reg [4:0] cfg_coreset_start_sym;  // TDATA[41:37]: symbol bat dau
    reg [1:0] cfg_duration;           // TDATA[43:42]: 1, 2 hoac 3 symbol
    reg [19:0] cfg_reserved;          // TDATA[63:44]: phai bang 0

    // -------------------------------------------------------------------------
    // FSM toi uu gom 5 state.
    // -------------------------------------------------------------------------
    localparam [2:0] ST_IDLE  = 3'd0; // Cho va nhan cau hinh
    localparam [2:0] ST_INIT  = 3'd1; // Kiem tra va chot tham so tinh toan
    localparam [2:0] ST_NORM  = 3'd2; // Dua shift ve nho hon n_bundle
    localparam [2:0] ST_WRITE = 3'd3; // Mapping va ghi mot REG moi chu ky
    localparam [2:0] ST_OUT   = 3'd4; // Giu output den khi ready

    reg [2:0] state;

    wire cfg_accept;

    assign s_axis_cfg_tready = (state == ST_IDLE);
    assign cfg_accept = s_axis_cfg_tvalid && s_axis_cfg_tready;

    // -------------------------------------------------------------------------
    // Cac thanh ghi trung gian thuc su can qua nhieu chu ky.
    // -------------------------------------------------------------------------
    reg [11:0] n_bundle;          // Tong so REG bundle trong CORESET
    reg [11:0] column_count;      // So cot C cua interleaver
    reg [11:0] start_bundle;      // Logical bundle dau tien cua PDCCH
    reg [6:0]  total_bundle;      // Tong so bundle cua PDCCH hien tai
    reg [11:0] normalized_shift;  // Shift da dua ve nho hon n_bundle

    reg [5:0] bundle_counter;     // Bundle dang xu ly, toi da 47
    reg [2:0] reg_in_bundle;      // REG thu may trong bundle, tu 0 den L-1

    // -------------------------------------------------------------------------
    // Logic to hop tinh tham so tu cau hinh.
    // -------------------------------------------------------------------------
    wire [4:0]  w_al_value;
    wire [11:0] w_n_reg;
    wire [2:0]  w_effective_bundle_size;
    wire [2:0]  w_bundle_per_cce;
    wire [11:0] w_n_bundle;
    wire [11:0] w_column_count;
    wire [11:0] w_start_bundle;
    wire [6:0]  w_total_bundle;

    wire [12:0] w_l_rebuilt_reg_count;
    wire [12:0] w_r_rebuilt_bundle_count;
    wire [12:0] w_selected_bundle_end;
    wire        w_config_valid;

    // Ma AL thuc te.
    assign w_al_value =
        (cfg_al == 3'd0) ? 5'd1  :
        (cfg_al == 3'd1) ? 5'd2  :
        (cfg_al == 3'd2) ? 5'd4  :
        (cfg_al == 3'd3) ? 5'd8  :
        (cfg_al == 3'd4) ? 5'd16 :
                           5'd0;

    // Tong so REG trong CORESET.
    assign w_n_reg =
        {2'b00, cfg_rb_number} * {10'b0, cfg_duration};

    // Non-interleaved duoc xu ly nhu cac bundle L bang 6.
    assign w_effective_bundle_size =
        cfg_interleaver_mode ? cfg_bundle_size : 3'd6;

    // Mot CCE co 6 REG, do do co 6 chia L bundle.
    assign w_bundle_per_cce =
        (w_effective_bundle_size == 3'd2) ? 3'd3 :
        (w_effective_bundle_size == 3'd3) ? 3'd2 :
        (w_effective_bundle_size == 3'd6) ? 3'd1 :
                                            3'd0;

    // Tong so bundle cua CORESET.
    assign w_n_bundle =
        (w_effective_bundle_size == 3'd2) ? (w_n_reg >> 1)     :
        (w_effective_bundle_size == 3'd3) ? (w_n_reg / 12'd3) :
        (w_effective_bundle_size == 3'd6) ? (w_n_reg / 12'd6) :
                                            12'd0;

    // So cot cua ma tran interleaver: C bang n_bundle chia R.
    assign w_column_count =
        (!cfg_interleaver_mode)        ? w_n_bundle           :
        (cfg_interleaver_size == 3'd2) ? (w_n_bundle >> 1)    :
        (cfg_interleaver_size == 3'd3) ? (w_n_bundle / 12'd3) :
        (cfg_interleaver_size == 3'd6) ? (w_n_bundle / 12'd6) :
                                          12'd0;

    // Bundle logic dau tien va tong so bundle can map.
    assign w_start_bundle =
        {4'd0, cfg_cce_start} * {9'd0, w_bundle_per_cce};

    assign w_total_bundle =
        {2'd0, w_al_value} * {4'd0, w_bundle_per_cce};

    // Dung phep nhan nguoc de kiem tra N_REG chia het cho L.
    assign w_l_rebuilt_reg_count =
        (w_effective_bundle_size == 3'd2) ?
            ({1'b0, w_n_bundle} << 1) :
        (w_effective_bundle_size == 3'd3) ?
            (({1'b0, w_n_bundle} << 1) + {1'b0, w_n_bundle}) :
        (w_effective_bundle_size == 3'd6) ?
            (({1'b0, w_n_bundle} << 2) +
             ({1'b0, w_n_bundle} << 1)) :
            13'd0;

    // Dung phep nhan nguoc de kiem tra n_bundle chia het cho R.
    assign w_r_rebuilt_bundle_count =
        (!cfg_interleaver_mode) ?
            {1'b0, w_n_bundle} :
        (cfg_interleaver_size == 3'd2) ?
            ({1'b0, w_column_count} << 1) :
        (cfg_interleaver_size == 3'd3) ?
            (({1'b0, w_column_count} << 1) +
             {1'b0, w_column_count}) :
        (cfg_interleaver_size == 3'd6) ?
            (({1'b0, w_column_count} << 2) +
             ({1'b0, w_column_count} << 1)) :
            13'd0;

    assign w_selected_bundle_end =
        {1'b0, w_start_bundle} + {6'd0, w_total_bundle};

    // Cau hinh chi hop le khi moi phep chia deu chia het va PDCCH
    // khong vuot khoi pham vi CORESET.
    assign w_config_valid =
        (w_al_value != 5'd0) &&
        (cfg_rb_number != 10'd0) &&
        (cfg_rb_number <= MAX_RB_VALUE) &&
        ((cfg_duration == 2'd1) ||
         (cfg_duration == 2'd2) ||
         (cfg_duration == 2'd3)) &&
        (cfg_coreset_start_sym < 5'd14) &&
        (cfg_reserved == 20'd0) &&
        (({1'b0, cfg_coreset_start_sym} +
          {4'd0, cfg_duration}) <= 6'd14) &&
        (w_bundle_per_cce != 3'd0) &&
        (w_n_bundle != 12'd0) &&
        (w_l_rebuilt_reg_count == {1'b0, w_n_reg}) &&
        (w_total_bundle != 7'd0) &&
        (w_selected_bundle_end <= {1'b0, w_n_bundle}) &&
        (
            (!cfg_interleaver_mode) ||
            (
                ((cfg_interleaver_size == 3'd2) ||
                 (cfg_interleaver_size == 3'd3) ||
                 (cfg_interleaver_size == 3'd6)) &&
                (w_column_count != 12'd0) &&
                (w_r_rebuilt_bundle_count == {1'b0, w_n_bundle})
            )
        );

    // Logic to hop mapping bundle hien tai.
    wire [11:0] w_logical_bundle;
    wire [11:0] w_div_r3;
    wire [11:0] w_div_r6;
    wire [11:0] w_rem_r3;
    wire [11:0] w_rem_r6;
    wire [11:0] w_bundle_row;
    wire [11:0] w_bundle_col;
    wire [11:0] w_row_times_column;
    wire [11:0] w_permuted_bundle;
    wire [12:0] w_shifted_bundle;
    wire [11:0] w_mapped_bundle;

    assign w_logical_bundle =
        start_bundle + {6'd0, bundle_counter};

    // Thuong va so du cho R bang 3 va R bang 6.
    assign w_div_r3 = w_logical_bundle / 12'd3;
    assign w_div_r6 = w_logical_bundle / 12'd6;

    assign w_rem_r3 =
        w_logical_bundle - w_div_r3 - (w_div_r3 << 1);

    assign w_rem_r6 =
        w_logical_bundle - (w_div_r6 << 2) - (w_div_r6 << 1);

    // r bang logical_bundle chia du R.
    assign w_bundle_row =
        (!cfg_interleaver_mode)        ? 12'd0 :
        (cfg_interleaver_size == 3'd2) ?
            {11'd0, w_logical_bundle[0]} :
        (cfg_interleaver_size == 3'd3) ? w_rem_r3 :
        (cfg_interleaver_size == 3'd6) ? w_rem_r6 :
                                          12'd0;

    // c bang logical_bundle chia R.
    assign w_bundle_col =
        (!cfg_interleaver_mode)        ? w_logical_bundle       :
        (cfg_interleaver_size == 3'd2) ? (w_logical_bundle >> 1) :
        (cfg_interleaver_size == 3'd3) ? w_div_r3               :
        (cfg_interleaver_size == 3'd6) ? w_div_r6               :
                                          12'd0;

    // r nhan C, viet bang dich va cong de khong can bo nhan tong quat.
    assign w_row_times_column =
        (w_bundle_row == 12'd0) ? 12'd0 :
        (w_bundle_row == 12'd1) ? column_count :
        (w_bundle_row == 12'd2) ? (column_count << 1) :
        (w_bundle_row == 12'd3) ?
            ((column_count << 1) + column_count) :
        (w_bundle_row == 12'd4) ? (column_count << 2) :
        (w_bundle_row == 12'd5) ?
            ((column_count << 2) + column_count) :
            12'd0;

    // f0(x) bang r nhan C cong c, truoc khi cong shift.
    assign w_permuted_bundle =
        cfg_interleaver_mode ?
            (w_row_times_column + w_bundle_col) :
            w_logical_bundle;

    assign w_shifted_bundle =
        {1'b0, w_permuted_bundle} + {1'b0, normalized_shift};

    assign w_mapped_bundle =
        (!cfg_interleaver_mode) ? w_logical_bundle :
        (w_shifted_bundle >= {1'b0, n_bundle}) ?
            (w_shifted_bundle[11:0] - n_bundle) :
            w_shifted_bundle[11:0];

    // -------------------------------------------------------------------------
    // Chuyen mapped bundle thanh REG, sau do thanh symbol va RB.
    // -------------------------------------------------------------------------
    wire [12:0] w_bundle_reg_base;
    wire [12:0] w_reg_index;
    wire [12:0] w_reg_div3;
    wire [12:0] w_reg_rem3;
    wire [11:0] w_reg_rb;
    wire [1:0]  w_reg_symbol_offset;
    wire [5:0]  w_physical_symbol;
    wire [15:0] w_symbol_rb_base;
    wire [15:0] w_bitmap_index;
    wire [BITMAP_INDEX_WIDTH-1:0] w_bitmap_address;

    assign w_bundle_reg_base =
        (w_effective_bundle_size == 3'd2) ?
            ({1'b0, w_mapped_bundle} << 1) :
        (w_effective_bundle_size == 3'd3) ?
            (({1'b0, w_mapped_bundle} << 1) +
             {1'b0, w_mapped_bundle}) :
        (w_effective_bundle_size == 3'd6) ?
            (({1'b0, w_mapped_bundle} << 2) +
             ({1'b0, w_mapped_bundle} << 1)) :
            13'd0;

    assign w_reg_index =
        w_bundle_reg_base + {10'd0, reg_in_bundle};

    assign w_reg_div3 = w_reg_index / 13'd3;

    assign w_reg_rem3 =
        w_reg_index - w_reg_div3 - (w_reg_div3 << 1);

    // REG numbering: symbol offset thay doi nhanh hon RB.
    assign w_reg_rb =
        (cfg_duration == 2'd1) ? w_reg_index[11:0] :
        (cfg_duration == 2'd2) ? w_reg_index[12:1] :
        (cfg_duration == 2'd3) ? w_reg_div3[11:0]  :
                                 12'd0;

    assign w_reg_symbol_offset =
        (cfg_duration == 2'd1) ? 2'd0 :
        (cfg_duration == 2'd2) ? {1'b0, w_reg_index[0]} :
        (cfg_duration == 2'd3) ?
            ((w_reg_rem3 == 13'd0) ? 2'd0 :
             (w_reg_rem3 == 13'd1) ? 2'd1 : 2'd2) :
                                 2'd0;

    assign w_physical_symbol =
        {1'b0, cfg_coreset_start_sym} +
        {4'd0, w_reg_symbol_offset};

    assign w_symbol_rb_base =
        {10'd0, w_physical_symbol} * {6'd0, MAX_RB_VALUE};

    assign w_bitmap_index =
        w_symbol_rb_base + {4'd0, w_reg_rb};

    // Dia chi rut gon dung rieng cho phep chon bit cua vector bitmap.
    // Dieu kien w_bitmap_index nho hon BITMAP_LIMIT duoc kiem tra truoc khi ghi.
    assign w_bitmap_address =
        w_bitmap_index[BITMAP_INDEX_WIDTH-1:0];

    // -------------------------------------------------------------------------
    // Tien trinh dong bo duy nhat. Tat ca thanh ghi dung suon duong clk.
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state                    <= ST_IDLE;

            cfg_cce_start            <= 8'd0;
            cfg_al                   <= 3'd0;
            cfg_bundle_size          <= 3'd0;
            cfg_interleaver_mode     <= 1'b0;
            cfg_interleaver_size     <= 3'd0;
            cfg_rb_number            <= 10'd0;
            cfg_shift_index          <= 9'd0;
            cfg_coreset_start_sym    <= 5'd0;
            cfg_duration             <= 2'd0;
            cfg_reserved             <= 20'd0;

            n_bundle                 <= 12'd0;
            column_count             <= 12'd0;
            start_bundle             <= 12'd0;
            total_bundle             <= 7'd0;
            normalized_shift         <= 12'd0;

            bundle_counter           <= 6'd0;
            reg_in_bundle            <= 3'd0;

            pdcch_rb_bitmap          <= {BITMAP_WIDTH{1'b0}};
            pdcch_rb_bitmap_valid    <= 1'b0;
        end
        else begin
            case (state)
                ST_IDLE: begin
                    pdcch_rb_bitmap_valid <= 1'b0;

                    if (cfg_accept) begin
                        cfg_cce_start         <= s_axis_cfg_tdata[7:0];
                        cfg_al                <= s_axis_cfg_tdata[10:8];
                        cfg_bundle_size       <= s_axis_cfg_tdata[13:11];
                        cfg_interleaver_mode  <= s_axis_cfg_tdata[14];
                        cfg_interleaver_size  <= s_axis_cfg_tdata[17:15];
                        cfg_rb_number         <= s_axis_cfg_tdata[27:18];
                        cfg_shift_index       <= s_axis_cfg_tdata[36:28];
                        cfg_coreset_start_sym <= s_axis_cfg_tdata[41:37];
                        cfg_duration          <= s_axis_cfg_tdata[43:42];
                        cfg_reserved          <= s_axis_cfg_tdata[63:44];

                        n_bundle              <= 12'd0;
                        column_count          <= 12'd0;
                        start_bundle          <= 12'd0;
                        total_bundle          <= 7'd0;
                        normalized_shift      <= 12'd0;
                        bundle_counter        <= 6'd0;
                        reg_in_bundle         <= 3'd0;
                        pdcch_rb_bitmap       <= {BITMAP_WIDTH{1'b0}};

                        state                 <= ST_INIT;
                    end
                end

                ST_INIT: begin
                    if (w_config_valid) begin
                        n_bundle      <= w_n_bundle;
                        column_count  <= w_column_count;
                        start_bundle  <= w_start_bundle;
                        total_bundle  <= w_total_bundle;
                        bundle_counter <= 6'd0;
                        reg_in_bundle  <= 3'd0;

                        if (cfg_interleaver_mode) begin
                            normalized_shift <= {3'd0, cfg_shift_index};
                            state            <= ST_NORM;
                        end
                        else begin
                            normalized_shift <= 12'd0;
                            state            <= ST_WRITE;
                        end
                    end
                    else begin
                        // Cau hinh sai: tra ve bitmap rong.
                        n_bundle               <= 12'd0;
                        column_count           <= 12'd0;
                        start_bundle           <= 12'd0;
                        total_bundle           <= 7'd0;
                        normalized_shift       <= 12'd0;
                        pdcch_rb_bitmap_valid <= 1'b1;
                        state                  <= ST_OUT;
                    end
                end

                ST_NORM: begin
                    // Phep tru lap thay cho toan tu chia du.
                    if (normalized_shift >= n_bundle) begin
                        normalized_shift <= normalized_shift - n_bundle;
                    end
                    else begin
                        state <= ST_WRITE;
                    end
                end

                ST_WRITE: begin
                    // Ghi mot bit cho REG hien tai neu dia chi hop le.
                    if ((w_reg_index < {1'b0, w_n_reg}) &&
                        (w_reg_rb < {2'b00, cfg_rb_number}) &&
                        (w_reg_rb < {2'b00, MAX_RB_VALUE}) &&
                        (w_physical_symbol < 6'd14) &&
                        (w_bitmap_index < BITMAP_LIMIT)) begin
                        pdcch_rb_bitmap[w_bitmap_address] <= 1'b1;
                    end

                    // Het cac REG cua bundle hien tai.
                    if (({1'b0, reg_in_bundle} + 4'd1) >=
                        {1'b0, w_effective_bundle_size}) begin
                        reg_in_bundle <= 3'd0;

                        // Het tat ca bundle cua PDCCH.
                        if (({1'b0, bundle_counter} + 7'd1) >=
                            total_bundle) begin
                            pdcch_rb_bitmap_valid <= 1'b1;
                            state                 <= ST_OUT;
                        end
                        else begin
                            bundle_counter <= bundle_counter + 6'd1;
                        end
                    end
                    else begin
                        reg_in_bundle <= reg_in_bundle + 3'd1;
                    end
                end

                ST_OUT: begin
                    // Khong gan lai bitmap tai day, vi vay bitmap va valid
                    // duoc giu on dinh trong toan bo thoi gian ready bang 0.
                    if (pdcch_rb_bitmap_ready) begin
                        pdcch_rb_bitmap_valid <= 1'b0;
                        state                 <= ST_IDLE;
                    end
                end

                default: begin
                    state                  <= ST_IDLE;
                    pdcch_rb_bitmap_valid  <= 1'b0;
                end
            endcase
        end
    end

endmodule