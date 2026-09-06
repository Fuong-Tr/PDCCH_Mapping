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


module cce_to_reg_mapper #(
    parameter DW = 32,
    parameter MAX_RB = 108
)(
    input wire aclk,
    input wire aresetn,
    
    //input
    input wire [63:0] s_axis_cfg_tdata,
    input wire  s_axis_cfg_tvalid,
    output wire  s_axis_cfg_tready,
    
    //ouput
    output reg [(MAX_RB*14)-1:0] pdcch_rb_bitmap
    );
    
    //phan tich input
    reg [7:0] cfg_cce_start;
    reg [2:0] cfg_al;
    reg [2:0] cfg_bundle_size;
    reg       cfg_interleaver_mod;
    reg [2:0] cfg_interleaver_size;
    reg [9:0] cfg_rb_number;
    reg [8:0] cfg_shift_index;
    reg [4:0] cfg_coreset_start_sym;
    reg [1:0] cfg_duration;
    
    //gan output
    
    
    always @(posedge aclk) begin
        
    end
    
    always @(posedge aclk) begin
    
    end
    
endmodule
