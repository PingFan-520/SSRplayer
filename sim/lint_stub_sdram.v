// 仅用于 ModelSim lint 的 SDRAM 控制器占位（真实的是 rtl/mem/sdram.v + 加密 IP）
`timescale 1ns / 1ps
module sdram(
    input  wire        Clk,
    input  wire        Clk_sft,
    input  wire        Rst,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    output wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
    assign Sdr_init_done = 1'b1;
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy = 1'b0;
    assign Sdr_rd_en = App_rd_en;
    assign Sdr_rd_dout = 32'd0;
endmodule
