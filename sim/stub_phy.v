// 仅用于 ModelSim lint 的 HDMI PHY 占位（真实实现用 lane_lvds_10_1 + EG_LOGIC_IO）
`timescale 1ns / 1ps
module hdmi_phy_wrapper #(parameter DEVICE = "EG")(
    input  wire      I_pixel_clk,
    input  wire      I_serial_clk,
    input  wire      I_rst,
    input  wire[9:0] I_tmds_channel_0,
    input  wire[9:0] I_tmds_channel_1,
    input  wire[9:0] I_tmds_channel_2,
    input  wire[9:0] I_tmds_channel_clk,
    output wire      O_tmds_ch0_p,
    output wire      O_tmds_ch1_p,
    output wire      O_tmds_ch2_p,
    output wire      O_tmds_clk_p
);
    assign O_tmds_ch0_p = I_tmds_channel_0[0];
    assign O_tmds_ch1_p = I_tmds_channel_1[0];
    assign O_tmds_ch2_p = I_tmds_channel_2[0];
    assign O_tmds_clk_p = I_tmds_channel_clk[0];
endmodule
