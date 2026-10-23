// ============================================================================
//  top_board.v —— 上板顶层（康芯 HX4S20 / EG4S20BG256）
//
//  链路：
//    50MHz -> PLL(37.5 / 187.5MHz)
//          -> color_bar + pattern_b + transition + param + menu（top_osd_demo）
//          -> rgb2axis -> HDMI 1.4b core -> phy -> HDMI 接口
//
//  为什么是 37.5MHz（720p30 / CEA VIC 4）：
//    SDRAM 控制器实测读带宽只有 7.51M 字/s，而 720p60 下显示 640x480 图片
//    行内瞬时需求是 640px/22.2us = 14.4M 字/s —— 差一半，FIFO 6 行就耗空，
//    图像每 32 像素错 6 个（81% 正确率）。把像素时钟减半后行时间变成 44.4us，
//    需求降到 7.2M，再配合 frame_buffer 的 16 字长 burst，才真正有余量。
//    H/V 时序参数一个字都没改（仍是 1650x750），只是时钟减半 -> 30Hz。
//    如果显示器不认 30Hz：把 CLKC0_DIV 改回 10、CLKC1_DIV 改回 2、
//    VIDEO_VIC 改回 16 即回到 720p60（带宽不足，图片会错位但能出图）。
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
    // PLL：50MHz -> 37.5MHz 像素 / 187.5MHz 串行 / 125MHz+125MHz(移相) SDRAM
    //   VCO = 50 x 15 = 750MHz
    //   CLKC0 = 750/20 = 37.5MHz      CLKC1 = 750/4  = 187.5MHz
    //   CLKC2 = 750/6  = 125MHz       CLKC3 = 750/6  = 125MHz（CPHASE 差 3
    //   个 VCO = 4ns = 半个周期，对应参考工程的 Clk_sft）
    // ------------------------------------------------------------------
    wire clk_pix, clk_ser, clk_mem, clk_mem_sft, pll_lock;

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
        .CLKC0_DIV      (20),
        .CLKC0_CPHASE   (19),
        .CLKC0_FPHASE   (0),
        .CLKC1_ENABLE   ("ENABLE"),
        .CLKC1_DIV      (4),
        .CLKC1_CPHASE   (3),
        .CLKC1_FPHASE   (0),
        .CLKC2_ENABLE   ("ENABLE"),
        .CLKC2_DIV      (6),
        .CLKC2_CPHASE   (5),
        .CLKC2_FPHASE   (0),
        .CLKC3_ENABLE   ("ENABLE"),
        .CLKC3_DIV      (6),
        .CLKC3_CPHASE   (2),
        .CLKC3_FPHASE   (0)
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
        .clkc       ({open, clk_mem_sft, clk_mem, clk_ser, clk_pix})
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
    // 统一声明（跨模块互连，避免使用前未声明）
    // ------------------------------------------------------------------
    wire [23:0] rgb;
    wire        hs, vs, de;
    wire [11:0] x, y;

    wire        raw_de;
    wire [11:0] raw_x, raw_y;

    wire        pat_en, pat_run;
    wire [11:0] pat_x, pat_y;
    wire [15:0] pat_rgb;
    wire        pat_done;

    // ------------------------------------------------------------------
    // SDRAM（封装内 SIP，厂商控制器）
    // ------------------------------------------------------------------
    wire        sdr_init_done, sdr_ref_vld, sdr_busy, sdr_rd_valid;
    wire [31:0] sdr_rd_dout;

    wire [20:0] fb_wr_addr, fb_rd_addr;
    wire [31:0] fb_wr_din;
    wire        fb_wr_en, fb_rd_en;

    sdram u_sdram (
        .Clk              (clk_mem),
        .Clk_sft          (clk_mem_sft),
        .Rst              (~rst_n),

        .Sdr_init_done    (sdr_init_done),
        .Sdr_init_ref_vld (sdr_ref_vld),
        .Sdr_busy         (sdr_busy),

        .App_wr_en        (fb_wr_en),
        .App_wr_addr      (fb_wr_addr),
        .App_wr_dm        (4'h0),
        .App_wr_din       (fb_wr_din),

        .App_rd_en        (fb_rd_en),
        .App_rd_addr      (fb_rd_addr),
        .Sdr_rd_en        (sdr_rd_valid),
        .Sdr_rd_dout      (sdr_rd_dout)
    );

    // ------------------------------------------------------------------
    // 帧缓存：只存 640x480 的图片区，黑边不进 SDRAM
    // ------------------------------------------------------------------
    wire [15:0] fb_rgb;
    wire        fb_de, fb_rdy;

    reg         load_mode;

    frame_buffer #(
        .FB_W(1280), .FB_H(720), .VACTIVE(720),
        .WR_LINES(25), .V_OFFSET(25),
        .IMG_W(640), .IMG_H(480), .IMG_X0(320), .IMG_Y0(120)
    ) u_fb (
        .app_wr_addr  (fb_wr_addr),
        .app_wr_din   (fb_wr_din),
        .app_wr_en    (fb_wr_en),
        .app_rd_addr  (fb_rd_addr),
        .app_rd_en    (fb_rd_en),
        .app_rd_valid (sdr_rd_valid),
        .app_rd_dout  (sdr_rd_dout),
        .app_init_done(sdr_init_done),
        .app_ref_vld  (sdr_ref_vld),
        .app_busy     (sdr_busy),

        .clk_mem (clk_mem),
        .rst_mem (~rst_n),

        .pix_clk (clk_pix),
        .pix_rst (~rst_n),
        .wr_en   (pat_en),
        .wr_x    (pat_x),
        .wr_y    (pat_y),
        .wr_rgb  (pat_rgb),
        .wr_buf  (1'b0),
        .wr_ready(fb_rdy),

        .vs      (vs),
        .de      (raw_de),
        .x       (raw_x),
        .y       (raw_y),
        .rd_buf  (1'b0),
        .load_mode(load_mode),
        .rgb_out (fb_rgb),
        .de_out  (fb_de)
    );

    // ------------------------------------------------------------------
    // 图案源：上电写一帧 640x480 彩条网格进 SDRAM
    //   （接上 SD 卡后这一段会换成 bmp_decode 的输出）
    // ------------------------------------------------------------------
    reg [3:0] st_cnt;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) st_cnt <= 4'd0;
        else if (st_cnt != 4'hF) st_cnt <= st_cnt + 4'd1;
    end
    wire pat_start = (st_cnt == 4'hE);

    pattern_src #(
        .IMG_W(640), .IMG_H(480), .X0(320), .Y0(120)
    ) u_pat (
        .clk(clk_pix), .rst(~rst_n),
        .start(pat_start), .ready(fb_rdy),
        .en(pat_en), .x(pat_x), .y(pat_y), .rgb(pat_rgb),
        .run(pat_run), .done(pat_done)
    );

    // 加载结束后等写 FIFO 排空，再切到"边读边显示"
    reg        pat_done_d;
    reg [11:0] ld_dly;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            pat_done_d <= 1'b0;
            ld_dly     <= 12'd0;
            load_mode  <= 1'b1;
        end else begin
            pat_done_d <= pat_done;
            if (load_mode && pat_done_d && u_fb.wf_empty) begin
                if (ld_dly == 12'd2000) load_mode <= 1'b0;
                else                    ld_dly    <= ld_dly + 12'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 画面 + 菜单
    // ------------------------------------------------------------------
    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire [7:0]  dbg_prog;
    wire [1:0]  dbg_effect;

    top_osd_demo #(
        .HACTIVE(HACTIVE), .HTOTAL(HTOTAL), .HSA(HSA), .HBP(HBP), .HFP(HFP),
        .VACTIVE(VACTIVE), .VTOTAL(VTOTAL), .VSA(VSA), .VBP(VBP), .VFP(VFP),
        .PX0(360), .PY0(110), .PW(560), .PH(500),
        .HOLD_FRAMES(75),                 // 30fps 下 2.5s 换一张
        .KEY_CLK_HZ(37_500_000),
        .USE_EXT(1)
    ) u_core (
        .clk(clk_pix), .rst_n(rst_n),
        .key({key2, key4, key3, key1}),      // {OK, DOWN, UP, MENU}
        .rgb_out(rgb), .hs_out(hs), .vs_out(vs), .de_out(de),
        .x_out(x), .y_out(y),
        .menu_open(menu_open), .dbg_item(dbg_item), .dbg_val(dbg_val),
        .dbg_prog(dbg_prog), .dbg_effect(dbg_effect),
        .seg_sel(seg_sel), .seg_data(seg_data),
        .ext_rgb(fb_rgb),
        .raw_de(raw_de), .raw_x(raw_x), .raw_y(raw_y)
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
    // HDMI 1.4b 发送核（720p30, VIC 4；H/V 时序仍是 1650x750）
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
        .VIDEO_VIC         (4),
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
