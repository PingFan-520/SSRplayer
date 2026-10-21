// ============================================================================
//  top_board.v —— 上板顶层（康芯 HX4S20 / EG4S20BG256）
//
//  链路：
//    50MHz -> PLL(75 / 375MHz)
//          -> color_bar + pattern_b + transition + param + menu（top_osd_demo）
//          -> rgb2axis -> HDMI 1.4b core -> phy -> HDMI 接口
//
//  按键（均为低有效，板上 KEY1~KEY4）：
//    KEY1(A2) = MENU 开合        KEY3(B1) = UP
//    KEY4(B2) = DOWN             KEY2(C1) = OK
//
//  复位：不再占用按键，改为 PLL 锁定 + 上电计数释放。
// ============================================================================
`timescale 1ns / 1ps

module top_board #(
    parameter integer HACTIVE = 1280,
    parameter integer HTOTAL  = 1650,
    parameter integer HSA     = 40,
    parameter integer HBP     = 220,
    parameter integer HFP     = 110,
    parameter integer VACTIVE = 720,
    parameter integer VTOTAL  = 750,
    parameter integer VSA     = 5,
    parameter integer VBP     = 20,
    parameter integer VFP     = 5
)(
    input  wire        clk_50m,       // R7

    input  wire        key1,          // A2  MENU
    input  wire        key2,          // C1  OK
    input  wire        key3,          // B1  UP
    input  wire        key4,          // B2  DOWN

    output wire        HDMI_CLK_P,
    output wire        HDMI_D0_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA,

    output wire [5:0]  seg_sel,
    output wire [7:0]  seg_data
);

    // ------------------------------------------------------------------
    // PLL：50MHz -> 75MHz 像素 / 375MHz 串行（已在 ModelSim 实测 75.000/375.0）
    // ------------------------------------------------------------------
    wire clk_pix, clk_ser, pll_lock;

    EG_PHY_PLL #(
        .DPHASE_SOURCE  ("DISABLE"),
        .DYNCFG         ("DISABLE"),
        .FIN            ("50.000000"),
        .FEEDBK_MODE    ("NORMAL"),
        .FEEDBK_PATH    ("VCO_PHASE_0"),
        .STDBY_ENABLE   ("DISABLE"),
        .PLLRST_ENA     ("ENABLE"),
        .SYNC_ENABLE    ("DISABLE"),
        .GMC_GAIN       (2),
        .ICP_CURRENT    (9),
        .KVCO           (2),
        .LPF_CAPACITOR  (1),
        .LPF_RESISTOR   (8),
        .REFCLK_DIV     (1),
        .FBCLK_DIV      (15),
        .CLKC0_ENABLE   ("ENABLE"),
        .CLKC0_DIV      (10),
        .CLKC0_CPHASE   (9),
        .CLKC0_FPHASE   (0),
        .CLKC1_ENABLE   ("ENABLE"),
        .CLKC1_DIV      (2),
        .CLKC1_CPHASE   (1),
        .CLKC1_FPHASE   (0)
    ) u_pll (
        .refclk     (clk_50m),
        .reset      (1'b0),
        .stdby      (1'b0),
        .extlock    (pll_lock),
        .load_reg   (5'b00000),
        .psclk      (1'b0),
        .psdown     (1'b0),
        .psstep     (1'b0),
        .psclksel   (3'b000),
        .psdone     (),
        .dclk       (1'b0),
        .dcs        (1'b0),
        .dwe        (1'b0),
        .di         (8'h00),
        .daddr      (6'h00),
        .do         (),
        .fbclk      (1'b0),
        .clkc       ({open, open, open, clk_ser, clk_pix})
    );

    // ------------------------------------------------------------------
    // 复位：PLL 锁定后释放；再等 2^20 拍让内部状态稳定
    // ------------------------------------------------------------------
    reg [19:0] por_cnt;
    reg        rst_n;

    always @(posedge clk_pix) begin
        if (!pll_lock) begin
            por_cnt <= 20'd0;
            rst_n   <= 1'b0;
        end else if (!por_cnt[19]) begin
            por_cnt <= por_cnt + 20'd1;
            rst_n   <= 1'b0;
        end else begin
            rst_n   <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 画面 + 菜单
    // ------------------------------------------------------------------
    wire [23:0] rgb;
    wire        hs, vs, de;
    wire [11:0] x, y;
    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire [7:0]  dbg_prog;
    wire [1:0]  dbg_effect;

    top_osd_demo #(
        .HACTIVE(HACTIVE), .HTOTAL(HTOTAL), .HSA(HSA), .HBP(HBP), .HFP(HFP),
        .VACTIVE(VACTIVE), .VTOTAL(VTOTAL), .VSA(VSA), .VBP(VBP), .VFP(VFP),
        .PX0(360), .PY0(110), .PW(560), .PH(500),
        .HOLD_FRAMES(150),
        .KEY_CLK_HZ(75_000_000)
    ) u_core (
        .clk(clk_pix), .rst_n(rst_n),
        .key({key2, key4, key3, key1}),      // {OK, DOWN, UP, MENU}
        .rgb_out(rgb), .hs_out(hs), .vs_out(vs), .de_out(de),
        .x_out(x), .y_out(y),
        .menu_open(menu_open), .dbg_item(dbg_item), .dbg_val(dbg_val),
        .dbg_prog(dbg_prog), .dbg_effect(dbg_effect),
        .seg_sel(seg_sel), .seg_data(seg_data)
    );

    // ------------------------------------------------------------------
    // RGB -> AXIS
    // ------------------------------------------------------------------
    wire        axis_user, axis_valid, axis_last;
    wire [23:0] axis_data;

    rgb2axis #(.HACTIVE(HACTIVE)) u_rgb2axis (
        .I_clk(clk_pix), .I_rst(~rst_n),
        .I_vs(vs), .I_de(de), .I_rgb(rgb),
        .O_video_user(axis_user), .O_video_valid(axis_valid),
        .O_video_last(axis_last), .O_video_data(axis_data)
    );

    // ------------------------------------------------------------------
    // EDID 读取触发：上电后约 1.3ms 给一个脉冲
    // ------------------------------------------------------------------
    reg [19:0] edid_cnt;
    reg        edid_trig;

    always @(posedge clk_pix) begin
        if (!rst_n) begin
            edid_cnt  <= 20'd0;
            edid_trig <= 1'b0;
        end else if (!edid_cnt[19]) begin
            edid_cnt  <= edid_cnt + 20'd1;
            edid_trig <= (edid_cnt == 20'hF0000);
        end else begin
            edid_trig <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // HDMI 1.4b 发送核（720p60, VIC 16）
    // ------------------------------------------------------------------
    wire [9:0] tmds_ch0, tmds_ch1, tmds_ch2, tmds_clk;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE            ("EG"),
        .HTOTAL            (HTOTAL),
        .HSA               (HSA),
        .HFP               (HFP),
        .HBP               (HBP),
        .HACTIVE           (HACTIVE),
        .VTOTAL            (VTOTAL),
        .VSA               (VSA),
        .VFP               (VFP),
        .VBP               (VBP),
        .VACTIVE           (VACTIVE),
        .VIDEO_VIC         (16),
        .VIDEO_TPG         ("Disable"),
        .VIDEO_FORMAT      ("RGB"),
        .AUDIO_SAMPLE_RATE ("48K"),
        .IIC_SCL_DIV       (250)
    ) u_hdmi (
        .I_pixel_clk       (clk_pix),
        .I_rst             (~rst_n),
        .I_edid_read_trig  (edid_trig),
        .O_edid_read_valid (),
        .O_edid_read_data  (),

        .I_axis_s_user     (axis_user),
        .I_axis_s_valid    (axis_valid),
        .I_axis_s_last     (axis_last),
        .I_axis_s_data     (axis_data),
        .O_axis_s_ready    (),

        .I_audio_valid     (1'b0),
        .I_audio_left_data (24'd0),
        .I_audio_right_data(24'd0),
        .I_acr_valid       (1'b0),
        .I_acr_cts         (20'd0),
        .I_acr_n           (20'd0),

        .O_video_locked    (),
        .O_ddc_scl         (HDMI_DDC_SCL),
        .IO_ddc_sda        (HDMI_DDC_SDA),

        .O_ch0_tmds_data   (tmds_ch0),
        .O_ch1_tmds_data   (tmds_ch1),
        .O_ch2_tmds_data   (tmds_ch2),
        .O_clk_tmds_data   (tmds_clk)
    );

    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy (
        .I_pixel_clk        (clk_pix),
        .I_serial_clk       (clk_ser),
        .I_rst              (~rst_n),
        .I_tmds_channel_0   (tmds_ch0),
        .I_tmds_channel_1   (tmds_ch1),
        .I_tmds_channel_2   (tmds_ch2),
        .I_tmds_channel_clk (tmds_clk),
        .O_tmds_ch0_p       (HDMI_D0_P),
        .O_tmds_ch1_p       (HDMI_D1_P),
        .O_tmds_ch2_p       (HDMI_D2_P),
        .O_tmds_clk_p       (HDMI_CLK_P)
    );

endmodule
