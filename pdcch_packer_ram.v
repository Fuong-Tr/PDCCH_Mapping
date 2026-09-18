`timescale 1ns / 1ps

// ============================================================================
// PDCCH PACKER WITH INTERNAL RAM WRITE
//
// Chuc nang:
//   1. Nhan DATA QPSK va DMRS theo giao tiep AXI-Stream.
//   2. Ghep DATA + DMRS thanh thu tu 12 RE / 1 REG.
//   3. Ghi truc tiep tung RE da pack vao RAM noi bo.
//   4. Khi ghi du 72 * AL RE thi assert ram_write_done trong 1 chu ky.
//
// Quy uoc PDCCH trong 1 REG:
//   RE 0  : DATA
//   RE 1  : DMRS
//   RE 2  : DATA
//   RE 3  : DATA
//   RE 4  : DATA
//   RE 5  : DMRS
//   RE 6  : DATA
//   RE 7  : DATA
//   RE 8  : DATA
//   RE 9  : DMRS
//   RE 10 : DATA
//   RE 11 : DATA
//
// 1 CCE = 6 REG
// 1 REG = 12 RE
// => 1 CCE = 72 RE
// => Tong RE can ghi = 72 * Aggregation Level
//
// RAM:
//   - Moi dia chi chua 1 complex sample 32-bit.
//   - Addr 0 ... (72*AL-1)
//   - AL max = 16 => toi da 1152 RE
//
// Muc dich:
//   Ban nay giu nguyen y tuong cua pdcch_packer_minimal, nhung thay vi phat
//   stream ra ngoai, du lieu duoc ghi truc tiep vao RAM de cac khoi mapping
//   phia sau co the doc lai theo dia chi.
// ============================================================================

module pdcch_packer_ram (
    input  wire         aclk,
    input  wire         aresetn,

    // ------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------
    input  wire         cfg_valid,
    output wire         cfg_ready,
    input  wire [4:0]   cfg_aggregation_level,

    // ------------------------------------------------------------------------
    // PDCCH QPSK DATA stream
    // So mau yeu cau = 54 * AL
    // ------------------------------------------------------------------------
    input  wire [31:0]  s_axis_data_tdata,
    input  wire         s_axis_data_tvalid,
    output wire         s_axis_data_tready,
    input  wire         s_axis_data_tlast,

    // ------------------------------------------------------------------------
    // PDCCH DMRS stream
    // So mau yeu cau = 18 * AL
    // ------------------------------------------------------------------------
    input  wire [31:0]  s_axis_dmrs_tdata,
    input  wire         s_axis_dmrs_tvalid,
    output wire         s_axis_dmrs_tready,
    input  wire         s_axis_dmrs_tlast,

    // ------------------------------------------------------------------------
    // RAM read port
    // Khoi mapping phia sau dua dia chi vao ram_rd_addr de doc lai sample.
    // ------------------------------------------------------------------------
    input  wire [10:0]  ram_rd_addr,
    output wire [31:0]  ram_rd_data,

    // ------------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------------
    output wire         busy,
    output reg          ram_write_done,
    output reg  [10:0]  ram_sample_count
);

    // =========================================================================
    // State machine
    // =========================================================================
    localparam ST_IDLE = 1'b0;
    localparam ST_PACK = 1'b1;

    reg state;

    // =========================================================================
    // Internal RAM
    // Max AL = 16
    // 72 * 16 = 1152 samples
    // =========================================================================
    reg [31:0] pdcch_ram [0:1151];

    // =========================================================================
    // Counters
    // =========================================================================
    reg [10:0] expected_output_count;
    reg [10:0] write_addr;

    // REG index: max 96 REG for AL=16
    reg [6:0]  reg_index;

    // RE position inside one REG: 0...11
    reg [3:0]  re_index;

    // =========================================================================
    // Internal selection signals
    // =========================================================================
    wire        select_dmrs;
    wire        selected_valid;
    wire [31:0] selected_data;
    wire        input_fire;
    wire        final_write_position;

    // TLAST input hien tai khong duoc dung de quyet dinh do dai packet.
    // Do dai packet duoc tinh truc tiep tu Aggregation Level.
    wire unused_input_tlast;
    assign unused_input_tlast = s_axis_data_tlast ^ s_axis_dmrs_tlast;

    // =========================================================================
    // Configuration / status
    // =========================================================================
    assign cfg_ready = (state == ST_IDLE);
    assign busy      = (state == ST_PACK);

    // =========================================================================
    // DATA / DMRS position selection
    //
    // Trong moi REG 12 RE:
    // DMRS tai RE = 1, 5, 9
    // Cac vi tri con lai la DATA
    // =========================================================================
    assign select_dmrs =
        (re_index == 4'd1) ||
        (re_index == 4'd5) ||
        (re_index == 4'd9);

    assign selected_valid =
        select_dmrs ? s_axis_dmrs_tvalid
                    : s_axis_data_tvalid;

    assign selected_data =
        select_dmrs ? s_axis_dmrs_tdata
                    : s_axis_data_tdata;

    // =========================================================================
    // AXI-Stream READY
    //
    // RAM noi bo luon co the ghi 1 sample moi chu ky.
    // Vi vay READY chi phu thuoc vao:
    //   - dang o ST_PACK
    //   - loai sample dang can (DATA hay DMRS)
    // =========================================================================
    assign s_axis_data_tready =
        (state == ST_PACK) && !select_dmrs;

    assign s_axis_dmrs_tready =
        (state == ST_PACK) &&  select_dmrs;

    // Handshake cua sample dang duoc chon
    assign input_fire =
        selected_valid &&
        (select_dmrs ? s_axis_dmrs_tready
                     : s_axis_data_tready);

    // Dia chi cuoi cua packet hien tai
    assign final_write_position =
        (write_addr == (expected_output_count - 11'd1));

    // =========================================================================
    // RAM asynchronous read
    //
    // De testbench va cac khoi sau co the doc truc tiep theo dia chi.
    // Neu can infer BRAM Vivado voi synchronous read, co the doi thanh always
    // @(posedge aclk) cho port doc.
    // =========================================================================
    assign ram_rd_data = pdcch_ram[ram_rd_addr];

    // =========================================================================
    // Main sequential logic
    // =========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            state                 <= ST_IDLE;
            expected_output_count <= 11'd0;
            write_addr            <= 11'd0;
            reg_index             <= 7'd0;
            re_index              <= 4'd0;

            ram_write_done        <= 1'b0;
            ram_sample_count      <= 11'd0;
        end else begin

            // Default: done chi assert trong 1 chu ky khi ket thuc packet
            ram_write_done <= 1'b0;

            case (state)

                // =============================================================
                // IDLE
                // Cho config moi
                // =============================================================
                ST_IDLE: begin
                    write_addr       <= 11'd0;
                    reg_index        <= 7'd0;
                    re_index         <= 4'd0;
                    ram_sample_count <= 11'd0;

                    if (cfg_valid && cfg_ready) begin
                        case (cfg_aggregation_level)

                            5'd1: begin
                                expected_output_count <= 11'd72;
                                state                 <= ST_PACK;
                            end

                            5'd2: begin
                                expected_output_count <= 11'd144;
                                state                 <= ST_PACK;
                            end

                            5'd4: begin
                                expected_output_count <= 11'd288;
                                state                 <= ST_PACK;
                            end

                            5'd8: begin
                                expected_output_count <= 11'd576;
                                state                 <= ST_PACK;
                            end

                            5'd16: begin
                                expected_output_count <= 11'd1152;
                                state                 <= ST_PACK;
                            end

                            default: begin
                                // AL khong hop le -> bo qua config
                                expected_output_count <= 11'd0;
                                state                 <= ST_IDLE;
                            end
                        endcase
                    end
                end

                // =============================================================
                // PACK
                // Chon DATA/DMRS theo re_index va ghi vao RAM.
                // =============================================================
                ST_PACK: begin

                    if (input_fire) begin

                        // -----------------------------------------------------
                        // Ghi sample da pack vao RAM
                        // -----------------------------------------------------
                        pdcch_ram[write_addr] <= selected_data;

                        // So sample da ghi
                        ram_sample_count <= ram_sample_count + 11'd1;

                        // -----------------------------------------------------
                        // Neu day la sample cuoi cua packet
                        // -----------------------------------------------------
                        if (final_write_position) begin
                            write_addr     <= 11'd0;
                            reg_index      <= 7'd0;
                            re_index       <= 4'd0;

                            ram_write_done <= 1'b1;
                            state          <= ST_IDLE;
                        end else begin

                            // Sang dia chi RAM tiep theo
                            write_addr <= write_addr + 11'd1;

                            // ---------------------------------------------
                            // Cap nhat vi tri RE / REG
                            // ---------------------------------------------
                            if (re_index == 4'd11) begin
                                re_index  <= 4'd0;
                                reg_index <= reg_index + 7'd1;
                            end else begin
                                re_index <= re_index + 4'd1;
                            end
                        end
                    end
                end

                default: begin
                    state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
