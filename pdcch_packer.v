`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/21/2026 09:47:00 AM
// Design Name: 
// Module Name: pdcch_packer
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
    localparam [1:0] ST_IDLE  = 2'd0; 
    localparam [1:0] ST_PACK  = 2'd1; 
    localparam [1:0] ST_DRAIN = 2'd2; 
    reg [1:0] state;
    reg [6:0] last_reg;  
    reg [6:0] reg_index; 
    reg [3:0] re_index;  
    reg out_valid;      

    wire select_dmrs;   
    wire output_space;  
    wire input_fire;    
    wire final_input;   
    
    
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
