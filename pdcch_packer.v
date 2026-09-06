`timescale 1ns / 1ps

module pdcch_packer_minimal (
    input  wire         aclk,
    input  wire         aresetn,

    // Configuration: cfg_aggregation_level is the actual AL value.
    input  wire         cfg_valid,
    output wire         cfg_ready,
    input  wire [4:0]   cfg_aggregation_level,

    // PDCCH QPSK DATA stream: 54 * AL complex samples.
    input  wire [31:0]  s_axis_data_tdata,
    input  wire         s_axis_data_tvalid,
    output wire         s_axis_data_tready,
    input  wire         s_axis_data_tlast,

    // PDCCH DMRS stream: 18 * AL complex samples.
    input  wire [31:0]  s_axis_dmrs_tdata,
    input  wire         s_axis_dmrs_tvalid,
    output wire         s_axis_dmrs_tready,
    input  wire         s_axis_dmrs_tlast,

    // Packed logical-REG stream: 72 * AL complex samples.
    output wire [31:0]  m_axis_re_tdata,
    output wire         m_axis_re_tvalid,
    input  wire         m_axis_re_tready,
    output wire         m_axis_re_tlast,
    output wire [11:0]  m_axis_re_tuser
);

    localparam ST_IDLE = 1'b0;
    localparam ST_PACK = 1'b1;

    reg        state;
    reg [10:0] expected_output_count;
    reg [10:0] output_count;
    reg [6:0]  reg_index;
    reg [3:0]  re_index;

    wire        select_dmrs;
    wire        selected_valid;
    wire [31:0] selected_data;
    wire        output_fire;
    wire        final_output_position;

    // The source TLAST inputs are retained for standard AXI4-Stream packet
    // compatibility. Packet completion is determined by AL-derived counts.
    wire unused_input_tlast;
    assign unused_input_tlast = s_axis_data_tlast ^ s_axis_dmrs_tlast;

    assign cfg_ready = (state == ST_IDLE);

    assign select_dmrs = (re_index == 4'd1) ||
                         (re_index == 4'd5) ||
                         (re_index == 4'd9);

    assign selected_valid = select_dmrs ? s_axis_dmrs_tvalid
                                        : s_axis_data_tvalid;
    assign selected_data  = select_dmrs ? s_axis_dmrs_tdata
                                        : s_axis_data_tdata;

    // Backpressure is propagated only to the source selected for this RE.
    assign s_axis_data_tready = (state == ST_PACK) &&
                                !select_dmrs && m_axis_re_tready;
    assign s_axis_dmrs_tready = (state == ST_PACK) &&
                                select_dmrs && m_axis_re_tready;

    assign m_axis_re_tvalid = (state == ST_PACK) && selected_valid;
    assign m_axis_re_tdata  = selected_data;

    assign final_output_position =
        (output_count == (expected_output_count - 11'd1));

    assign m_axis_re_tlast = m_axis_re_tvalid && final_output_position;

    // TUSER = {is_dmrs, RE offset inside REG, logical REG index}.
    assign m_axis_re_tuser = {select_dmrs, re_index, reg_index};

    assign output_fire = m_axis_re_tvalid && m_axis_re_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            state                 <= ST_IDLE;
            expected_output_count <= 11'd0;
            output_count          <= 11'd0;
            reg_index             <= 7'd0;
            re_index              <= 4'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    output_count <= 11'd0;
                    reg_index    <= 7'd0;
                    re_index     <= 4'd0;

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
                                // Invalid AL is ignored. Parser must provide
                                // one of the five supported values.
                                expected_output_count <= 11'd0;
                                state                 <= ST_IDLE;
                            end
                        endcase
                    end
                end

                ST_PACK: begin
                    if (output_fire) begin
                        if (final_output_position) begin
                            output_count <= 11'd0;
                            reg_index    <= 7'd0;
                            re_index     <= 4'd0;
                            state        <= ST_IDLE;
                        end else begin
                            output_count <= output_count + 11'd1;

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
