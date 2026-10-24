// ============================================================================
//  top_board.v —— 上板顶层（康芯 HX4S20 / EG4S20BG256）
//
//  链路：
//    SD 卡(SPI,25MHz) -> sd_ctrl_top -> sd_bmp_reader -> 异步FIFO
//       -> bmp_decode(RGB565+屏幕坐标) -> frame_buffer -> SDRAM
//       -> 显示侧读出 -> top_osd_demo(转场/菜单) -> rgb2axis -> HDMI
//
//  时钟（PLL，VCO=750MHz）：
//    CLKC0 = 37.5MHz  像素域（720p30 / CEA VIC 4）
//    CLKC1 = 187.5MHz HDMI 串行（5x 像素）
//    CLKC2 = 125MHz   SDRAM 控制器
//    CLKC3 = 125MHz   SDRAM 移相（CPHASE 差 3 个 VCO = 4ns = 半周期）
//    CLKC4 = 25MHz    SD SPI
//
//  为什么是 37.5MHz 而不是 75MHz：
//    SDRAM 控制器实测读带宽 7.5M 字/s，而 640x480 图片在 720p60 下
//    行内需求是 640px/22.2us = 14.4M 字/s —— 差一半，FIFO 几行就耗空。
//    像素时钟减半后行时间 44.4us、需求 7.2M；再加上读 FIFO 4096 深，
//    仿真与上板都是逐像素 0 误差。
//    H/V 参数没变（1650x750），只是时钟减半 -> 30Hz。
//    回退 60Hz：CLKC0_DIV=10、CLKC1_DIV=2、VIDEO_VIC=16。
//
//  按键（低有效）：KEY1(A2)=MENU  KEY3(B1)=UP  KEY4(B2)=DOWN  KEY2(C1)=OK
//  复位：PLL 锁定 + 上电计数释放。
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
    parameter integer VFP     = 5,
    // SD 卡上的图片布局（裸扇区，PC 端用 tools/make_sd_image.py 生成镜像）
    parameter integer SEC_BASE   = 2048,      // 第 0 张图起始扇区（1MB 偏移）
    parameter integer SEC_STRIDE = 1801,      // 每张图占 1801 扇区（=921654 字节）
    parameter integer IMG_NUM    = 6,         // 循环张数
    parameter integer HOLD_FRM   = 90         // 每张停留帧数（30fps 下 3 秒）
)(
    input  wire        clk_50m,       // R7

    input  wire        key1,          // A2  MENU
    input  wire        key2,          // C1  OK
    input  wire        key3,          // B1  UP
    input  wire        key4,          // B2  DOWN

    // SD 卡（SPI 模式）
    output wire        sd_clk,        // A14
    output wire        sd_cs,         // A12
    input  wire        sd_miso,       // B14
    output wire        sd_mosi,       // A13

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
    // PLL：5 路输出
    // ------------------------------------------------------------------
    wire clk_pix, clk_ser, clk_mem, clk_mem_sft, clk_sd, pll_lock;

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
        .CLKC3_FPHASE   (0),
        .CLKC4_ENABLE   ("ENABLE"),
        .CLKC4_DIV      (30),
        .CLKC4_CPHASE   (29),
        .CLKC4_FPHASE   (0)
    ) u_pll (
        .refclk     (clk_50m),
        .reset      (1'b0),
        .stdby      (1'b0),
        .extlock    (pll_lock),
        .load_reg   (1'b0),
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
        .clkc       ({clk_sd, clk_mem_sft, clk_mem, clk_ser, clk_pix})
    );

    // ------------------------------------------------------------------
    // 复位
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
    // 统一声明
    // ------------------------------------------------------------------
    wire [23:0] rgb;
    wire        hs, vs, de;
    wire [11:0] x, y;

    wire        raw_de;
    wire [11:0] raw_x, raw_y;

    // ------------------------------------------------------------------
    // SDRAM
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
    // 帧缓存
    // ------------------------------------------------------------------
    wire [15:0] fb_rgb;
    wire        fb_de, fb_rdy;

    reg         load_mode;

    // 写侧数据源（BMP 解码器输出）
    wire        bmp_we;
    wire [11:0] bmp_x, bmp_y;
    wire [15:0] bmp_rgb;

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
        .wr_en   (bmp_we),
        .wr_x    (bmp_x),
        .wr_y    (bmp_y),
        .wr_rgb  (bmp_rgb),
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
    // SD 卡：SPI 控制器（25MHz）
    // ------------------------------------------------------------------
    wire        sd_init_done, sd_rd_busy, sd_rd_val_en, sd_rd_start_en;
    wire [31:0] sd_rd_sec_addr;
    wire [15:0] sd_rd_val_data;

    sd_ctrl_top u_sd (
        .clk_ref      (clk_sd),
        .rst_n        (rst_n),

        .sd_miso      (sd_miso),
        .sd_clk       (sd_clk),
        .sd_cs        (sd_cs),
        .sd_mosi      (sd_mosi),

        .rd_start_en  (sd_rd_start_en),
        .rd_sec_addr  (sd_rd_sec_addr),
        .rd_busy      (sd_rd_busy),
        .rd_val_en    (sd_rd_val_en),
        .rd_val_data  (sd_rd_val_data),

        .sd_init_done (sd_init_done)
    );

    // ------------------------------------------------------------------
    // 扇区连续读 + 字节流
    // ------------------------------------------------------------------
    wire [7:0] sd_byte;
    wire       sd_byte_vld;
    wire       rdr_busy;

    reg  [7:0] img_idx;
    reg        rd_en;              // pix 域电平请求（reader 用 done 应答）
    wire       rdr_done;

    sd_bmp_reader #(
        .SEC_BASE(SEC_BASE), .SEC_STRIDE(SEC_STRIDE), .SEC_NUM(SEC_STRIDE)
    ) u_rdr (
        .clk          (clk_sd),
        .rst          (~rst_n),

        .rd_start_en  (sd_rd_start_en),
        .rd_sec_addr  (sd_rd_sec_addr),
        .rd_busy      (sd_rd_busy),
        .rd_val_en    (sd_rd_val_en),
        .rd_val_data  (sd_rd_val_data),
        .sd_init_done (sd_init_done),

        .enable       (rd_en),
        .img_idx      (img_idx),
        .busy         (rdr_busy),
        .done         (rdr_done),

        .byte_data    (sd_byte),
        .byte_valid   (sd_byte_vld)
    );

    // 字节流跨到像素域
    wire [7:0] sfifo_dout;
    wire       sfifo_empty, sfifo_rvld, sfifo_rd;

    afifo #(.DW(8), .AW(9)) u_sfifo (
        .clk_w(clk_sd), .clk_r(clk_pix), .aclr(~rst_n),
        .wr_en(sd_byte_vld), .wr_data(sd_byte), .wr_full(),
        .rd_en(sfifo_rd), .rd_data(sfifo_dout), .rd_empty(sfifo_empty),
        .rd_valid(sfifo_rvld), .wr_used()
    );

    // afifo 是寄存器输出：读一次出一拍，rd_valid 期间不再读
    assign sfifo_rd = ~sfifo_empty & ~sfifo_rvld;

    // ------------------------------------------------------------------
    // BMP 解码（像素域）
    //   每次开始装载时给一个复位脉冲：reader 每张读 1801 扇区(922112B)，
    //   而 BMP 只有 921654B，多出的 458 字节没有 BM 头，
    //   不复位的话残留状态会把下一张的头部吃掉。
    // ------------------------------------------------------------------
    reg rd_en_d, bmp_rst;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            rd_en_d <= 1'b0;
            bmp_rst <= 1'b1;
        end else begin
            rd_en_d <= rd_en;
            bmp_rst <= 1'b0;
            if (rd_en & ~rd_en_d) bmp_rst <= 1'b1;   // rd_en 上升沿 = 新一张开始
        end
    end

    bmp_decode u_bmp (
        .clk        (clk_pix),
        .rst        (~rst_n | bmp_rst),
        .s_data     (sfifo_dout),
        .s_valid    (sfifo_rvld),
        .s_ready    (),
        .o_we       (bmp_we),
        .o_x        (bmp_x),
        .o_y        (bmp_y),
        .o_rgb565   (bmp_rgb),
        .o_frame_done(),
        .o_img_w    (),
        .o_img_h    (),
        .o_hdr_ok   ()
    );

    // ------------------------------------------------------------------
    // 轮播状态机（像素域）
    //   WAIT : 等 SD 初始化完成
    //   LOAD : load_mode=1，整帧只写不读；启动一次扇区读
    //   SHOW : load_mode=0，正常显示；停留 HOLD_FRM 帧后换下一张
    // ------------------------------------------------------------------
    localparam [1:0] LD_WAIT = 2'd0,
                     LD_ARM  = 2'd1,      // 换图后先让 img_idx 稳定
                     LD_LOAD = 2'd2,
                     LD_SHOW = 2'd3;

    reg [1:0]  ld_st;
    reg [12:0] fin_dly;
    reg [15:0] hold_frm;
    reg [1:0]  sdi_sync;
    reg        done_s1, done_s2;

    wire sd_ready  = sdi_sync[1];
    wire rdr_done_p = done_s2;
    wire frame_top = (raw_y == 12'd0) && (raw_x == 12'd0);

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            sdi_sync <= 2'b00;
            done_s1  <= 1'b0;
            done_s2  <= 1'b0;
        end else begin
            sdi_sync <= {sdi_sync[0], sd_init_done};
            done_s1  <= rdr_done;          // reader 的 done 是电平
            done_s2  <= done_s1;
        end
    end

    // 轮播：WAIT -> LOAD -> SHOW -> ARM -> LOAD ...
    //   LOAD 期间 load_mode=1（整帧只写不读），rd_en 保持高电平请求，
    //   reader 用 done 电平回答；不再依赖 busy 的边沿，避免毛刺误清请求。
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            ld_st     <= LD_WAIT;
            img_idx   <= 8'd0;
            rd_en     <= 1'b0;
            load_mode <= 1'b1;
            fin_dly   <= 13'd0;
            hold_frm  <= 16'd0;
        end else begin
            case (ld_st)
                LD_WAIT: begin
                    if (sd_ready) begin
                        rd_en   <= 1'b1;
                        fin_dly <= 13'd0;
                        ld_st   <= LD_LOAD;
                    end
                end

                // img_idx 是像素域的寄存器，SD 域要用它算起始扇区，
                // 换图后先等 16 拍（~427ns，远大于 2 个 25MHz 周期）再发请求，
                // 避免多比特总线正在变化时被采样。
                LD_ARM: begin
                    if (fin_dly == 13'd16) begin
                        rd_en   <= 1'b1;
                        fin_dly <= 13'd0;
                        ld_st   <= LD_LOAD;
                    end else begin
                        fin_dly <= fin_dly + 13'd1;
                    end
                end

                LD_LOAD: begin
                    load_mode <= 1'b1;
                    if (rdr_done_p) begin
                        if (fin_dly == 13'd4000) begin
                            load_mode <= 1'b0;
                            rd_en     <= 1'b0;   // 撤请求，让 reader 清 done
                            hold_frm  <= 16'd0;
                            ld_st     <= LD_SHOW;
                        end else begin
                            fin_dly <= fin_dly + 13'd1;
                        end
                    end
                end

                LD_SHOW: begin
                    if (frame_top) hold_frm <= hold_frm + 16'd1;
                    if (hold_frm >= HOLD_FRM[15:0]) begin
                        img_idx   <= (img_idx >= IMG_NUM[7:0] - 8'd1) ? 8'd0
                                                                     : (img_idx + 8'd1);
                        fin_dly   <= 13'd0;
                        ld_st     <= LD_ARM;
                    end
                end

                default: ld_st <= LD_WAIT;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 画面 + 菜单
    // ------------------------------------------------------------------
    // 数码管调试字（**要把数码管读数反过来拼**）：
    //   高半字节 = {img_idx[2:0], rdr_busy}   低半字节 = {ld_st, rd_en, sd_ready}
    //   ld_st: 0=WAIT 1=ARM 2=LOAD 3=SHOW
    wire [7:0]  dbg_ext = {img_idx[2:0], rdr_busy, ld_st, rd_en, sd_ready};

    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire [7:0]  dbg_prog;
    wire [1:0]  dbg_effect;

    top_osd_demo #(
        .HACTIVE(HACTIVE), .HTOTAL(HTOTAL), .HSA(HSA), .HBP(HBP), .HFP(HFP),
        .VACTIVE(VACTIVE), .VTOTAL(VTOTAL), .VSA(VSA), .VBP(VBP), .VFP(VFP),
        .PX0(360), .PY0(110), .PW(560), .PH(500),
        .HOLD_FRAMES(75),
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
        .raw_de(raw_de), .raw_x(raw_x), .raw_y(raw_y),
        .dbg_ext(dbg_ext)
    );

    // ------------------------------------------------------------------
    // RGB -> AXIS -> HDMI
    // ------------------------------------------------------------------
    wire        axis_user, axis_valid, axis_last;
    wire [23:0] axis_data;

    rgb2axis #(.HACTIVE(HACTIVE)) u_rgb2axis (
        .I_clk(clk_pix), .I_rst(~rst_n),
        .I_vs(vs), .I_de(de), .I_rgb(rgb),
        .O_video_user(axis_user), .O_video_valid(axis_valid),
        .O_video_last(axis_last), .O_video_data(axis_data)
    );

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
    // HDMI 音频：DDS 单音，音高跟随当前图片编号（换图变调 = 音视频联动）
    //   48kHz 采样，ACR: N=6144, CTS = 37.5MHz*6144/(128*48000) = 37500
    // ------------------------------------------------------------------
    wire        aud_valid;
    wire [23:0] aud_left, aud_right;

    tone_gen #(.CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)) u_tone (
        .clk       (clk_pix),
        .rst       (~rst_n),
        .note_idx  (img_idx),
        .mute      (1'b0),
        .aud_valid (aud_valid),
        .aud_left  (aud_left),
        .aud_right (aud_right)
    );

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

        .I_audio_valid     (aud_valid),
        .I_audio_left_data (aud_left),
        .I_audio_right_data(aud_right),
        .I_acr_valid       (1'b1),
        .I_acr_cts         (20'd37500),
        .I_acr_n           (20'd6144),

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
