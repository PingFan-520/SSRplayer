// ============================================================================
//  stub_hdmi_core.v —— 仅用于 ModelSim 语法/端口检查的 HDMI 核占位
//  真正的核是加密的 hdmi_1_4b_transmitter_core_wrapper.enc.v，只能在 TD 里综合。
//  【不要加入 TD 工程】
// ============================================================================
`timescale 1ns / 1ps

module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE            = "EG",
    parameter HTOTAL            = 1650,
    parameter HSA               = 40,
    parameter HFP               = 110,
    parameter HBP               = 220,
    parameter HACTIVE           = 1280,
    parameter VTOTAL            = 750,
    parameter VSA               = 5,
    parameter VFP               = 5,
    parameter VBP               = 20,
    parameter VACTIVE           = 720,
    parameter VIDEO_VIC         = 16,
    parameter VIDEO_TPG         = "Disable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter AUDIO_SAMPLE_RATE = "48K",
    parameter IIC_SCL_DIV       = 250
)(
    input  wire        I_pixel_clk,
    input  wire        I_rst,
    input  wire        I_edid_read_trig,
    output wire        O_edid_read_valid,
    output wire [7:0]  O_edid_read_data,
    input  wire        I_axis_s_user,
    input  wire        I_axis_s_valid,
    input  wire        I_axis_s_last,
    input  wire [23:0] I_axis_s_data,
    output wire        O_axis_s_ready,
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire        I_acr_valid,
    input  wire [19:0] I_acr_cts,
    input  wire [19:0] I_acr_n,
    output wire        O_video_locked,
    output wire        O_ddc_scl,
    inout  wire        IO_ddc_sda,
    output wire [9:0]  O_ch0_tmds_data,
    output wire [9:0]  O_ch1_tmds_data,
    output wire [9:0]  O_ch2_tmds_data,
    output wire [9:0]  O_clk_tmds_data
);

    assign O_edid_read_valid = 1'b0;
    assign O_edid_read_data  = 8'd0;
    assign O_axis_s_ready    = 1'b1;
    assign O_video_locked    = 1'b1;
    assign O_ddc_scl         = 1'b1;
    assign IO_ddc_sda        = 1'bz;
    assign O_ch0_tmds_data   = {10{I_axis_s_valid}};
    assign O_ch1_tmds_data   = {10{I_axis_s_last}};
    assign O_ch2_tmds_data   = 10'd0;
    assign O_clk_tmds_data   = 10'b1010101010;

endmodule
