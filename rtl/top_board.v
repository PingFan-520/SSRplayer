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
    // 图片数量不再写死：FAT32 根目录里有多少张 BMP 就循环多少张（上限 56）
    // 音乐区（tools/make_sd_image.py 会打印这三个数）
    // 音乐区布局由卡上的「目录扇区」给出，RTL 里不再写死 base/stride
    // 曲目数同样由 FAT32 目录决定（上限 6，菜单一页放得下）
    parameter integer HOLD_FRM   = 90,        // 每张停留帧数（30fps 下 3 秒）
    // 双缓冲开关：1 = 双缓冲（换图/淡入淡出转场必须用它）；0 = 单缓冲（换图黑一下）
    //   ★ 2026-10-25：从 0 改回 1。
    //   之前一直是 0（上次"改回单缓冲"后，那条 edit 的锚点文本已变，替换静默失败，
    //   于是后面所有版本实际都跑单缓冲），直接导致：
    //     ① 转场那条 if (USE_DBL && effect != CUT) 永远不成立 -> 换图是硬切，
    //        菜单里的转场特效全部无效（上板看到的"转场失效"就是这个）；
    //     ② 加载期 load_mode=1 -> 整屏黑一下。
    parameter integer USE_DBL    = 1
)(
    input  wire        clk_50m,       // R7

    input  wire        key1,          // A2  上   ：上一张 / 菜单内上移
    input  wire        key2,          // C1  列表 ：音乐列表 / 菜单内关闭
    input  wire        key3,          // B1  菜单 ：功能菜单 / 菜单内确认
    input  wire        key4,          // B2  下   ：下一张 / 菜单内下移

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
    wire [8:0]  fb_wf_used;
    wire        fb_wr_idle;

    reg         load_mode;
    reg         rd_bank, wr_bank;   // 双缓冲：显示 A 时写 B，反之亦然
    wire [1:0]  dbg_effect;         // 菜单里选的转场特效（提前声明，FSM 要用）
    wire [1:0]  dbg_scale;          // 菜单里选的缩放档位（给 bmp_scale）
    wire [3:0]  dbg_vol;            // 菜单音量 0..10
    wire [2:0]  dbg_mus;            // 菜单 MUS：0=关 1=内置 2..=SD 曲目
    wire        dbg_auto;
    wire [2:0]  dbg_hold;
    wire        dbg_style;           // 1=自动轮播
    wire        nav_next, nav_prev;  // 非菜单态下 KEY1/KEY2：下一张/上一张
    wire        aud_valid;          // 音频采样有效（给频谱）
    wire [23:0] aud_left, aud_right; // 音频输出（24bit）

    // 淡入淡出转场：255=正常亮度，0=全黑。换 bank 发生在全黑那一刻，看不见。
    reg  [7:0]  fade_lvl;
    reg         img_changed;        // 换图脉冲（给转场做淡入）
    reg  [1:0]  scale_d;            // 上一次加载用的缩放模式（变了就重载当前图）
    reg         first_img;          // 1 = 上电首张（不做转场）

    // ------------------------------------------------------------------
    // 擦除/推入式转场（菜单 SLIDE / WIPE）
    //   frame_buffer 按"显示行号"选 bank：rout < rd_wipe 读 rd_bank，否则读 rd_bank_new。
    //   每帧把分界挪 60 行，12 帧走完（约 0.4s），两张图同屏共存、没有黑场。
    //   整行切换，4 字 burst 绝不会跨 bank。
    // ------------------------------------------------------------------
    reg         rd_bank_new;        // 新图所在的 bank
    reg  [19:0] rd_wipe;            // 分界（显示行号）；720 = 全读 rd_bank
    reg         wipe_dir;           // 0 = SLIDE 新图从下往上推；1 = WIPE 新图从上往下覆盖
    reg  [3:0]  wipe_frm;           // 已走的帧数（兼作看门狗）

    // 图片铺满整个活动区（960x540 存储，显示时 4:3 上采样到 1280x720）
    localparam integer IMG_X0 = 0;
    localparam integer IMG_Y0 = 0;
    localparam integer V_OFF  = 25;                  // VSA+VBP，与 frame_buffer 一致

    // 写侧数据源：BMP 解码 -> 自适应缩放 -> 帧缓存
    wire        sc_we;
    wire        sc_busy;
    wire        sc_full;             // 这张图是否铺满整块（= 换图时不必清屏）
    wire [11:0] sc_x, sc_y;
    wire [15:0] sc_rgb;
    wire [7:0]  fb_rd_drop;           // 读通路丢字计数（>0 就会纵向错行）
    wire [2:0]  sc_k;
    reg         sc_clr;               // 换图前清屏（把整个 640x480 框写黑）
    wire        sc_clr_done, sc_clr_busy;

    frame_buffer #(
        .FB_W(1280), .FB_H(720), .VACTIVE(720),
        .WR_LINES(16), .V_OFFSET(V_OFF),
        .SW(960), .SH(540)
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
        .wr_en   (sc_we),
        .wr_x    (sc_x),
        .wr_y    (sc_y),
        .wr_rgb  (sc_rgb),
        .wr_buf  (1'b0),
        .wr_ready(fb_rdy),

        .vs      (vs),
        .de      (raw_de),
        .x       (raw_x),
        .y       (raw_y),
        .rd_buf  (1'b0),
        .load_mode(load_mode),
        .rd_bank (rd_bank),
        .rd_bank_new(rd_bank_new),
        .rd_wipe (rd_wipe),
        .wr_bank (wr_bank),
        .wr_fifo_used(fb_wf_used),
        .wr_idle (fb_wr_idle),
        .wr_drop (fb_wr_drop),
        .rd_drop_cnt(fb_rd_drop),
        .rgb_out (fb_rgb),
        .de_out  (fb_de)
    );

    // ------------------------------------------------------------------
    // SD 卡：SPI 控制器（25MHz）+ FAT32
    //   三个使用者：A 音频（最优先）/ B 图片 / C FAT 挂载与扫描
    // ------------------------------------------------------------------
    wire        sd_init_done, sd_rd_busy, sd_rd_val_en, sd_rd_start_en;
    wire [31:0] sd_rd_sec_addr;
    wire [15:0] sd_rd_val_data;

    wire        arb_start, arb_busy, arb_val;
    wire [31:0] arb_sec;
    wire [15:0] arb_data;

    wire        wav_req;
    wire [31:0] wav_sec;
    wire        wav_busy, wav_val, wav_gnt;
    wire [15:0] wav_data;

    wire        img_busy, img_val, img_gnt;
    wire [15:0] img_data;

    wire        scan_busy, scan_val, scan_gnt;
    wire [15:0] scan_data;

    // FAT 挂载 / 扫描的扇区请求（共用仲裁器 C 口）
    wire [2:0]  mnt_st;
    wire [3:0]  scan_st;
    wire        mnt_rd_start, scan_rd_start;
    wire [31:0] mnt_rd_sec, scan_rd_sec;

    // ------------------------------------------------------------------
    // SD 上电时序：init_done 会把 sd_clk 从 400kHz 切到 25MHz，而且卡在
    // ACMD41 之后还需要一点时间才接受 CMD17。
    // 旧版本第一次读卡在"清屏"之后（约 300ms），FAT 挂载却是 init_done
    // 的第一个周期就发命令 —— 卡一旦丢掉这条命令，sd_read 里没有超时，
    // rd_busy 永远不落，整个 SD 链路就死了（上板现象：数码管 01、黑屏）。
    // 旧版本第一次读卡在"清屏"之后（约 1s），这里统一等 ~671ms 再放行；
    // sd_reinit 时一起复位重来。
    // ------------------------------------------------------------------
    reg [23:0] sd_settle;
    always @(posedge clk_sd or negedge rst_n) begin
        if (!rst_n)                       sd_settle <= 24'd0;
        else if (!sd_init_done)           sd_settle <= 24'd0;
        else if (sd_settle != 24'hFFFFFF) sd_settle <= sd_settle + 24'd1;
    end
    wire sd_bus_ok = sd_init_done & (sd_settle == 24'hFFFFFF);

    // SD 子系统软复位（上电卡死时整段重来，见下面的 watchdog）
    //   复位是异步的，但"释放"要同步到 25MHz 域，避免恢复时间违例
    reg        sd_reinit;
    wire       sd_rst_n = rst_n & ~sd_reinit;

    reg [1:0]  sd_rst_sync;
    always @(posedge clk_sd or negedge rst_n) begin
        if (!rst_n) sd_rst_sync <= 2'b00;
        else        sd_rst_sync <= {sd_rst_sync[0], sd_rst_n};
    end
    wire sd_rst_n_s = sd_rst_sync[1];

    sd_ctrl_top u_sd (
        .clk_ref      (clk_sd),
        .rst_n        (sd_rst_n_s),

        .sd_miso      (sd_miso),
        .sd_clk       (sd_clk),
        .sd_cs        (sd_cs),
        .sd_mosi      (sd_mosi),

        .rd_start_en  (arb_start),
        .rd_sec_addr  (arb_sec),
        .rd_busy      (arb_busy),
        .rd_val_en    (arb_val),
        .rd_val_data  (arb_data),

        .sd_init_done (sd_init_done)
    );

    sd_arb u_arb (
        .clk(clk_sd), .rst_n(sd_rst_n_s),
        .a_req(wav_req), .a_sec(wav_sec),
        .a_busy(wav_busy), .a_val(wav_val), .a_data(wav_data), .a_gnt(wav_gnt),
        .b_req(sd_rd_start_en), .b_sec(sd_rd_sec_addr),
        .b_busy(img_busy), .b_val(img_val), .b_data(img_data), .b_gnt(img_gnt),
        .c_req(mnt_rd_start | scan_rd_start),
        .c_sec(mnt_rd_start ? mnt_rd_sec : scan_rd_sec),
        .c_busy(scan_busy), .c_val(scan_val), .c_data(scan_data), .c_gnt(scan_gnt),
        .s_start(arb_start), .s_sec(arb_sec),
        .s_busy(arb_busy), .s_val(arb_val), .s_data(arb_data),
        .sd_init_done(sd_bus_ok)
    );

    // ------------------------------------------------------------------
    // FAT32：挂载 -> 目录扫描 -> 文件表
    //   挂载和扫描共用仲裁器 C 口（两者严格先后，不会同时发请求）
    // ------------------------------------------------------------------
    wire        mnt_rd_busy, mnt_rd_val;
    wire [15:0] mnt_rd_data;
    wire        mnt_ok, mnt_done;
    wire [31:0] part_lba, fat_lba, data_lba, root_clus;
    wire [3:0]  spc_log2;
    wire [7:0]  mnt_err;

    fat_mnt u_mnt (
        .clk         (clk_sd),
        .rst         (~sd_rst_n_s),
        .rd_start_en (mnt_rd_start),
        .rd_sec_addr (mnt_rd_sec),
        .rd_busy     (scan_busy),
        .rd_val_en   (scan_val),
        .rd_val_data (scan_data),
        .sd_init_done(sd_bus_ok),
        .mnt_ok      (mnt_ok),
        .part_lba    (part_lba),
        .fat_lba     (fat_lba),
        .data_lba    (data_lba),
        .spc_log2    (spc_log2),
        .root_clus   (root_clus),
        .mnt_done    (mnt_done),
        .mnt_err     (mnt_err),
        .dbg_st      (mnt_st)
    );

    wire        scan_done;
    wire [7:0]  img_total_s;
    wire [3:0]  mus_total_s;
    wire [7:0]  scan_err;
    wire        tbl_wr_en;
    wire [9:0]  tbl_wr_addr;
    wire [7:0]  tbl_wr_data;

    fat_scan #(.IMG_MAX(56), .MUS_MAX(6)) u_scan (
        .clk         (clk_sd),
        .rst         (~sd_rst_n_s),
        .rd_start_en (scan_rd_start),
        .rd_sec_addr (scan_rd_sec),
        .rd_busy     (scan_busy),
        .rd_val_en   (scan_val),
        .rd_val_data (scan_data),
        .sd_init_done(sd_bus_ok),
        .mnt_ok      (mnt_ok),
        .mnt_done    (mnt_done),
        .fat_lba     (fat_lba),
        .data_lba    (data_lba),
        .spc_log2    (spc_log2),
        .root_clus   (root_clus),
        .tw_en       (tbl_wr_en),
        .tw_addr     (tbl_wr_addr),
        .tw_data     (tbl_wr_data),
        .img_total   (img_total_s),
        .mus_total   (mus_total_s),
        .scan_done   (scan_done),
        .scan_err    (scan_err),
        .dbg_st      (scan_st)
    );

    // 文件表：图片读器 + 音频播放器共用
    wire        img_tbl_req, img_tbl_done;
    wire [5:0]  img_tbl_rec;
    wire [127:0] img_tbl_data;
    wire        mus_tbl_req, mus_tbl_done;
    wire [5:0]  mus_tbl_rec;
    wire [127:0] mus_tbl_data;

    fat_tbl u_tbl (
        .clk    (clk_sd),
        .rst    (~rst_n),
        .wr_en  (tbl_wr_en),
        .wr_addr(tbl_wr_addr),
        .wr_data(tbl_wr_data),
        .i_req  (img_tbl_req), .i_rec(img_tbl_rec),
        .i_done (img_tbl_done), .i_data(img_tbl_data),
        .m_req  (mus_tbl_req), .m_rec(mus_tbl_rec),
        .m_done (mus_tbl_done), .m_data(mus_tbl_data)
    );

    // ------------------------------------------------------------------
    // 图片读器（按簇链）
    // ------------------------------------------------------------------
    wire [7:0] sd_byte;
    wire       sd_byte_vld;
    wire       rdr_busy;

    // 读失败标志跨到像素域（电平，打两拍）
    wire       rdr_err;            // 读失败（扇区重试用尽）
    wire [3:0] rdr_err_st;         // 出错时的 reader 状态快照（诊断）
    reg        err_s1, err_s2;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin err_s1 <= 1'b0; err_s2 <= 1'b0; end
        else        begin err_s1 <= rdr_err; err_s2 <= err_s1; end
    end
    wire rdr_err_p = err_s2;

    reg  [7:0] img_idx;
    reg        rd_en;              // pix 域电平请求（reader 用 done 应答）
    wire       rdr_done;
    wire       bmp_eof;            // 解码器已收满 bfSize（让读取器提前收工）

    sd_bmp_reader u_rdr (
        .clk          (clk_sd),
        .rst          (~rst_n),

        .rd_start_en  (sd_rd_start_en),
        .rd_sec_addr  (sd_rd_sec_addr),
        .rd_busy      (img_busy),
        .rd_val_en    (img_val),
        .rd_val_data  (img_data),
        .sd_init_done (sd_init_done),

        .fat_lba      (fat_lba),
        .data_lba     (data_lba),
        .spc_log2     (spc_log2),

        .tbl_req      (img_tbl_req),
        .tbl_rec      (img_tbl_rec),
        .tbl_done     (img_tbl_done),
        .tbl_data     (img_tbl_data),

        .enable       (rd_en),
        .img_idx      (img_idx),
        .fifo_used    (fb_wf_used),
        .stop         (bmp_eof),
        .busy         (rdr_busy),
        .done         (rdr_done),
        .err          (rdr_err),
        .err_st       (rdr_err_st),

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
    // ★ 反压：缩放器/帧缓存忙时停止取字节。
    //   字节停了，bmp_decode 就不会再吐像素，像素不会被静默丢掉。
    assign sfifo_rd = ~sfifo_empty & ~sfifo_rvld & ~sc_busy;

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

    wire        bmp_we;
    wire [11:0] bmp_sx, bmp_sy, bmp_x, bmp_y;
    wire [15:0] bmp_rgb, bmp_w, bmp_h;

    bmp_decode u_bmp (
        .clk        (clk_pix),
        .rst        (~rst_n | bmp_rst),
        .s_data     (sfifo_dout),
        .s_valid    (sfifo_rvld),
        .s_ready    (),
        .o_we       (bmp_we),
        .o_x        (bmp_x),
        .o_y        (bmp_y),
        .o_sx       (bmp_sx),
        .o_sy       (bmp_sy),
        .o_rgb565   (bmp_rgb),
        .o_eof      (bmp_eof),
        .o_frame_done(),
        .o_img_w    (bmp_w),
        .o_img_h    (bmp_h),
        .o_hdr_ok   ()
    );

    // 自适应缩放：任意分辨率的图 -> 960x540（1280x720 走精确 3/4 抽取）
    bmp_scale #(.DW(960), .DH(540)) u_scale (
        .clk      (clk_pix),
        .rst      (~rst_n),

        .s_we     (bmp_we),
        .s_sx     (bmp_sx),
        .s_sy     (bmp_sy),
        .s_rgb    (bmp_rgb),
        .img_w    (bmp_w),
        .img_h    (bmp_h),
        .mode     (dbg_scale),

        .clr      (sc_clr),
        .clr_done (sc_clr_done),
        .clr_busy (sc_clr_busy),

        .o_rdy    (fb_rdy),
        .o_we     (sc_we),
        .o_x      (sc_x),
        .o_y      (sc_y),
        .o_rgb    (sc_rgb),
        .o_k      (sc_k),
        .o_busy   (sc_busy),
        .o_full   (sc_full)
    );

    // ------------------------------------------------------------------
    // FAT 扫描结果 -> 像素域
    //   这些值在挂载/扫描结束后就不再变，逐位两级同步即可
    // ------------------------------------------------------------------
    reg [7:0]  tot_s1, tot_s2;
    reg [3:0]  mst_s1, mst_s2;
    reg        sdn_s1, sdn_s2;
    reg [63:0] nm_s1,  nm_s2;
    wire [63:0] wav_trk_name;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            tot_s1 <= 8'd0; tot_s2 <= 8'd0;
            mst_s1 <= 4'd0; mst_s2 <= 4'd0;
            sdn_s1 <= 1'b0; sdn_s2 <= 1'b0;
            nm_s1  <= 64'd0; nm_s2 <= 64'd0;
        end else begin
            tot_s1 <= img_total_s;  tot_s2 <= tot_s1;
            mst_s1 <= mus_total_s;  mst_s2 <= mst_s1;
            sdn_s1 <= scan_done;    sdn_s2 <= sdn_s1;
            nm_s1  <= wav_trk_name; nm_s2  <= nm_s1;
        end
    end

    wire [7:0]  img_total_p = tot_s2;
    wire [3:0]  mus_total_p = mst_s2;
    wire        scan_done_p = sdn_s2;
    wire [63:0] mus_name_p  = nm_s2;


    // ------------------------------------------------------------------
    // 轮播状态机（像素域）
    //   WAIT : 等 SD 初始化完成
    //   LOAD : load_mode=1，整帧只写不读；启动一次扇区读
    //   SHOW : load_mode=0，正常显示；停留 HOLD_FRM 帧后换下一张
    // ------------------------------------------------------------------
    localparam [2:0] LD_WAIT  = 3'd0,
                     LD_CLEAR = 3'd1,     // 把整个图片区写黑（缩放后留边不会残留上一张）
                     LD_ARM   = 3'd2,     // 换图后先让 img_idx 稳定
                     LD_LOAD  = 3'd3,
                     LD_FADE_OUT = 3'd5,  // 淡出到黑
                     LD_FADE_IN  = 3'd6,  // 从黑淡入新图（换 bank 在两者之间完成）
                     LD_WIPE     = 3'd7,  // 擦除/推入（按 rd_wipe 分界选 bank）
                     LD_SHOW  = 3'd4;

    reg [2:0]  ld_st;
    reg [12:0] fin_dly;
    reg        clr_ok;          // 清屏完成标志（clr_done 只有 1 拍，必须锁存）
    reg [25:0] clr_wdog;        // 清屏看门狗（26 位 = 1.8s）

    // ★ 一次切图的总计时（从"开始换图"那一拍起，饱和，绝不回绕）
    //   旧版用 ld_wdog 兼职三件事：进度节拍、加载超时、进度的清零条件。
    //   结果在 LD_LOAD 里它只在 !rdr_done 时累加，超时又写成"等于某值"只成立 1 拍，
    //   超时收不干净 -> 32 位没饱和 -> 7.16s 回绕一次 -> "ld_wdog==0" 把进度清零，
    //   于是数码管 0→99 反复、一次切图几十秒。现在计时只做一件事：饱和计数。
    reg [27:0] sw_tmr;

    // 诊断：本次切图一共进了几次 LD_LOAD。
    //   每次按键/自动切图清零，在静止态显示在数码管最左一位。
    //   01 = 只加载了一次（那"0→99 反复"就只是进度显示问题）
    //   03 = 真的反复加载了 3 次
    reg [3:0]  load_cnt;

    // 加载失败（超时 / reader 报错）后的自愈重试：每次切图只重试一次。
    //   reinit_pulse 交给下面 boot_tmr 那一段去拉 sd_reinit。
    reg        ld_retry;
    reg        reinit_pulse;
    reg [7:0]  wait_hold;       // 自愈重试后 LD_WAIT 的静默期（约 6.8us，只为跳过指示信号的 2~3 拍滞后）


    // ------------------------------------------------------------------
    // 切图决策：手动（KEY1/KEY2）优先、自动（菜单 AUT）按档位计时。
    // 全部集中在 nav_ctrl 里，top_board 只负责"收到 step 就开始换图"。
    //   手动按键会挂起等显示态，加载/转场期间按下也不会丢（上板 bug）
    //   自动关掉时计数恒 0，"OFF 却自己切"在结构上不可能（上板 bug）
    // ------------------------------------------------------------------
    wire        nav_step, nav_step_prev;
    wire [15:0] nav_hold_cnt;

    reg [1:0]  sdi_sync;
    reg        done_s1, done_s2;

    wire sd_ready   = sdi_sync[1];

    // 开机看门狗：SD 一直没就绪（没插卡/卡坏）也在屏幕上给个提示，
    // 不要只留一块黑屏
    reg [25:0] boot_cnt;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) boot_cnt <= 26'd0;
        else if (!sd_ready && (boot_cnt != 26'h3FFFFFF)) boot_cnt <= boot_cnt + 26'd1;
    end
    wire boot_tmo = boot_cnt[25];        // 约 0.9s @37.5MHz

    // 提示"没有可用图片"：扫到 0 张、扫描/挂载报错、或卡一直没就绪，
    // 都别只留一块黑屏（上板排查时最难判断的就是"到底卡在哪"）
    wire media_alert = (scan_done_p && (img_total_p == 8'd0)) ||
                       (scan_err != 8'd0) || (mnt_err != 8'd0) ||
                       (~sd_ready && boot_tmo);
    wire rdr_done_p = done_s2;

    // 当前这一行是不是"图片行"（帧内行号 25..744，图片已铺满活动区）。
    // 换 bank 必须避开这段：否则本帧上面还是旧图、下面已经换成新图。
    wire in_img_row = (raw_y >= V_OFF) && (raw_y < (V_OFF + 720));

    // 写侧排空标志跨到像素域（mem 125MHz -> pix 37.5MHz）
    reg  [1:0] widle_sync;
    wire       wr_idle_p = widle_sync[1];

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) widle_sync <= 2'b00;
        else        widle_sync <= {widle_sync[0], fb_wr_idle};
    end
    wire frame_top = (raw_y == 12'd0) && (raw_x == 12'd0);

    nav_ctrl u_nav (
        .clk       (clk_pix),
        .rst       (~rst_n),
        .frame_tick(frame_top),
        .showing   (ld_st == LD_SHOW),
        .auto_en   (dbg_auto),
        .hold_sel  (dbg_hold),
        .key_next  (nav_next),
        .key_prev  (nav_prev),
        .step      (nav_step),
        .step_prev (nav_step_prev),
        .hold_cnt  (nav_hold_cnt)
    );

    // ------------------------------------------------------------------
    // 一次切图的计时（唯一计时源）
    //   ld_start : 切图决策那一拍（按键 / 自动 / 缩放重载）
    //   ld_run   : 正在换图的那些状态（清屏 / ARM / 读图 / 转场）
    //   ld_tmo   : 3.4s 硬超时 —— 电平，一旦到点就一直保持到下一次切图，
    //              所以"看门狗要成立 65 拍才能收工"这件事不会再因为
    //              比较值只成立 1 拍而永远收不了工。
    // ------------------------------------------------------------------
    wire ld_start = (ld_st == LD_SHOW) && (nav_step || (dbg_scale != scale_d));
    wire ld_run   = (ld_st != LD_SHOW) && (ld_st != LD_WAIT);
    wire ld_tmo   = (sw_tmr >= 28'd127_500_000);          // 3.4s @37.5MHz

    // 自愈重试也要把计时/进度清零，否则第二次加载一进来就"已超时"
    wire sw_rst   = ld_start || reinit_pulse;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)                        sw_tmr <= 28'd0;
        else if (sw_rst)                   sw_tmr <= 28'd0;
        else if (ld_run && (sw_tmr != 28'hFFFFFFF)) sw_tmr <= sw_tmr + 28'd1;
    end


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
            sc_clr    <= 1'b0;
            clr_ok    <= 1'b0;
            clr_wdog  <= 24'd0;
            load_cnt  <= 4'd0;
            ld_retry  <= 1'b0;
            reinit_pulse <= 1'b0;
            wait_hold <= 8'd0;
            load_mode <= 1'b1;          // 只有首次为 1：此时读停、整帧写 A
            rd_bank   <= 1'b0;
            wr_bank   <= 1'b0;
            rd_bank_new <= 1'b0;
            rd_wipe   <= 20'd720;
            wipe_dir  <= 1'b0;
            wipe_frm  <= 4'd0;
            fade_lvl  <= 8'd255;
            img_changed <= 1'b0;
            scale_d   <= 2'd0;
            first_img <= 1'b1;
            fin_dly   <= 13'd0;
        end else begin
            if (ld_st != LD_LOAD) img_changed <= 1'b0;
            reinit_pulse <= 1'b0;

            case (ld_st)
                LD_WAIT: begin
                    // ★ 复位 SD 段之后不能马上信 sd_ready/scan_done：
                    //   这两个信号要 2~3 拍才会落下来，自愈重试时如果立刻放行，
                    //   会拿着"还没挂载"的 fat_lba/data_lba 去读图，必错。
                    //   所以给一小段静默期（6.8us），之后还要等 sd_ready 重新起来。
                    if (wait_hold != 8'd0) begin
                        wait_hold <= wait_hold - 8'd1;
                    end else if (sd_ready && scan_done_p && (img_total_p != 8'd0)) begin
                        sc_clr   <= 1'b1;     // 先清屏，再开始读图
                        clr_ok   <= 1'b0;
                        clr_wdog <= 26'd0;
                        fin_dly  <= 13'd0;
                        ld_st    <= LD_CLEAR;
                    end
                end

                // 清屏：把 640x480 框整块写 0，避免缩放留边处露出上一张的内容。
                // 153600 字，只在写窗口里跑，约 57ms（首张 load_mode=1 时约 20ms）。
                LD_CLEAR: begin
                    sc_clr <= 1'b0;
                    // 清屏也要走 0.6s，进度靠 sw_tmr 自己走，这里不用管
                    // 清屏结束还要等写 FIFO 排空：清屏最后那 256 个字可能正卡在
                    // 写窗口外。FIFO 满着就开读的话，刚开始的像素会被丢掉。
                    //
                    // 关键：clr_done 是**1 拍脉冲**，而它出现时 FIFO 里还有几百个字
                    // （wr_idle 还是 0）。直接写 "clr_done && wr_idle" 会漏掉那唯一
                    // 1 拍 -> 永久停在 CLEAR（上板实测：黑屏 + 数码管 03）。
                    // 所以先把完成标志锁存下来。
                    if (sc_clr_done) clr_ok <= 1'b1;

                    if (!wr_idle_p) clr_wdog <= clr_wdog + 26'd1;

                    if ((clr_ok && wr_idle_p) || (clr_wdog == 26'h3FFFFFF)) begin
                        fin_dly  <= 13'd0;
                        clr_ok   <= 1'b0;
                        clr_wdog <= 26'd0;
                        ld_st    <= LD_ARM;
                    end
                end

                // img_idx 是像素域的寄存器，SD 域要用它算起始扇区，
                // 换图后先等 16 拍（~427ns，远大于 2 个 25MHz 周期）再发请求，
                // 避免多比特总线正在变化时被采样。
                LD_ARM: begin
                    if (fin_dly == 13'd16) begin
                        rd_en    <= 1'b1;
                        fin_dly  <= 13'd0;
                        if (load_cnt != 4'hF) load_cnt <= load_cnt + 4'd1;
                        ld_st    <= LD_LOAD;
                    end else begin
                        fin_dly <= fin_dly + 13'd1;
                    end
                end

                LD_LOAD: begin
                    if (!USE_DBL[0]) load_mode <= 1'b1;   // 单缓冲：整帧只写不读
                    // 注意：这里不再拉高 load_mode。首次之后 load_mode 恒 0，
                    // 读写靠"图片行 vs 非图片行"在时间上分离，读侧永不中断。
                    //
                    // 换 bank 的条件：SD 读完 + 写侧彻底排空 + 64 拍余量。
                    // 只等固定 4000 拍是不够的：最后一批像素可能正卡在写窗口外，
                    // 窗口最坏 21ms 才开，提前换 bank 会把尾巴写进下一块缓冲。
                    // 再要求"当前不在图片行"：换 bank 只在消隐期发生，
                    // 否则这一帧会上面旧图、下面新图（看起来像两张图拼接）
                    // 加载超时保护：SD 万一读不完（坏块/接触不良），
                    // 3.4 秒后强制收工，至少把已经写进去的部分显示出来，
                    // 而不是永远卡在 LOAD（黑屏）。
                    // ★ 超时用 ld_tmo（电平保持），不是"等于某个计数值"——
                    //   后者只成立 1 拍，收工条件（fin_dly 数到 64）永远凑不满。

                    // 读失败（扇区重试用尽）或加载超时：
                    //   先自愈重试一次 —— 把 SD 段（sd_ctrl_top/arb/mnt/scan + reader）
                    //   整体复位，回 LD_WAIT 重新挂载扫描，然后再读这张图。
                    //   上板实测"卡一次之后就再也起不来"，就是没人给它复位。
                    //   第二次还失败才按老路收工（保留旧图 / 首张继续等）。
                    if (((rdr_err_p && rdr_done_p) || ld_tmo) && !ld_retry) begin
                        ld_retry     <= 1'b1;
                        reinit_pulse <= 1'b1;
                        wait_hold    <= 8'hFF;       // 6.8us 静默期，跳过指示信号滞后
                        rd_en        <= 1'b0;
                        fin_dly      <= 13'd0;
                        ld_st        <= LD_WAIT;
                    end else if (rdr_err_p && rdr_done_p) begin
                        rd_en     <= 1'b0;
                        fin_dly   <= 13'd0;
                        wait_hold <= 8'hFF;
                        ld_st     <= first_img ? LD_WAIT : LD_SHOW;
                    end else if ((rdr_done_p && wr_idle_p && !in_img_row) ||
                        ld_tmo) begin
                        if (fin_dly == 13'd64) begin
                            rd_en     <= 1'b0;   // 撤请求，让 reader 清 done
                            load_mode <= 1'b0;
                            // 转场：按菜单里选的特效分四种
                            //   FADE(0)  淡出到黑 -> 换 bank（看不见）-> 淡入
                            //   SLIDE(1) 新图从下往上推入（分界 153600 -> 0）
                            //   WIPE(2)  新图从上往下覆盖（分界 0 -> 153600）
                            //   CUT(3)   硬切
                            // 交叉淡化要同时读新旧两个地址，单读口带宽不够，
                            // 所以 FADE 走"中间经过全黑"的经典做法；
                            // SLIDE/WIPE 复用 frame_buffer 的 rd_wipe 分界选 bank。
                            if (first_img || !USE_DBL[0]) begin
                                // 上电首张：直接硬切，不做任何转场
                                // （正常上电就该立刻出图，而不是先黑一下再淡入）
                                first_img   <= 1'b0;
                                rd_bank     <= USE_DBL[0] ? wr_bank : 1'b0;
                                wr_bank     <= USE_DBL[0] ? ~wr_bank : 1'b0;
                                rd_bank_new <= USE_DBL[0] ? wr_bank : 1'b0;
                                rd_wipe     <= 20'd720;
                                fade_lvl    <= 8'd255;
                                ld_st       <= LD_SHOW;
                            end else if (!USE_DBL[0]) begin
                                // 单缓冲：没有第二块可读，只能硬切
                                rd_bank     <= 1'b0;
                                wr_bank     <= 1'b0;
                                rd_bank_new <= 1'b0;
                                rd_wipe     <= 20'd720;
                                fade_lvl    <= 8'd255;
                                ld_st       <= LD_SHOW;
                            end else begin
                                case (dbg_effect)
                                    2'd0: begin      // FADE
                                        fade_lvl <= 8'd255;
                                        rd_bank_new <= wr_bank;
                                        rd_wipe     <= 20'd720;
                                        ld_st       <= LD_FADE_OUT;
                                    end
                                    2'd1: begin      // SLIDE：新图从下往上推
                                        rd_bank_new <= wr_bank;      // 新图
                                        rd_wipe     <= 20'd720;   // 先全读旧图
                                        wipe_dir    <= 1'b0;
                                        wipe_frm    <= 4'd0;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_WIPE;
                                    end
                                    2'd2: begin      // WIPE：新图从上往下覆盖
                                        // 交换角色：rd_bank 放新图、rd_bank_new 放旧图，
                                        // 分界 0 -> 153600，上半部分逐帧变成新图。
                                        rd_bank_new <= rd_bank;      // 旧图
                                        rd_bank     <= wr_bank;      // 新图
                                        rd_wipe     <= 20'd0;
                                        wipe_dir    <= 1'b1;
                                        wipe_frm    <= 4'd0;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_WIPE;
                                    end
                                    default: begin   // CUT：硬切
                                        rd_bank     <= wr_bank;
                                        rd_bank_new <= wr_bank;
                                        rd_wipe     <= 20'd720;
                                        wr_bank     <= ~wr_bank;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_SHOW;
                                    end
                                endcase
                            end
                        end else begin
                            fin_dly <= fin_dly + 13'd1;
                        end
                    end
                end

                // 整幅推入：每帧把分界下移 15360 字（= 48 行），10 帧推完。
                // 分界必须整 4 字对齐（15360 / 320 都是 4 的倍数），
                // 这样 4 字 burst 绝不会跨 bank，控制器不会读到错位数据。
                // 淡出：每帧 -32，8 帧从 255 降到 0（约 0.27s）
                LD_FADE_OUT: begin
                    if (frame_top) begin
                        if (fade_lvl <= 8'd32) begin
                            fade_lvl <= 8'd0;              // 全黑
                            rd_bank  <= USE_DBL[0] ? wr_bank : 1'b0;
                            wr_bank  <= USE_DBL[0] ? ~wr_bank : 1'b0;
                            ld_st    <= LD_FADE_IN;        // 黑屏里换 bank，看不见
                        end else begin
                            fade_lvl <= fade_lvl - 8'd32;
                        end
                    end
                end

                // 淡入新图：每帧 +32，8 帧回到 255
                LD_FADE_IN: begin
                    if (frame_top) begin
                        if (fade_lvl >= 8'd224) begin
                            fade_lvl <= 8'd255;
                            ld_st    <= LD_SHOW;
                        end else begin
                            fade_lvl <= fade_lvl + 8'd32;
                        end
                    end
                end

                // ------------------------------------------------------------------
                // 擦除/推入转场：每帧把分界挪 15360 字（= 48 行），11 帧走完。
                //   分界恒 4 字对齐（153600 / 15360 / 320 都能被 4 整除），
                //   4 字 burst 绝不会跨 bank。
                //   wipe_dir=0（SLIDE）：153600 -> 0，新图从下往上推入；
                //   wipe_dir=1（WIPE） ：0 -> 153600，新图从上往下覆盖。
                //   只在 frame_top 改分界（此时 rd_cnt 正在归零），不会半帧撕裂。
                // ------------------------------------------------------------------
                LD_WIPE: begin
                    if (frame_top) begin
                        if (wipe_frm >= 4'd13) begin
                            // 看门狗：无论什么情况，13 帧内必定收尾，不会卡死
                            rd_wipe     <= 20'd720;
                            rd_bank     <= wipe_dir ? rd_bank : rd_bank_new;
                            rd_bank_new <= wipe_dir ? rd_bank : rd_bank_new;
                            wr_bank     <= ~(wipe_dir ? rd_bank : rd_bank_new);
                            wipe_frm    <= 4'd0;
                            ld_st       <= LD_SHOW;
                        end else begin
                            wipe_frm <= wipe_frm + 4'd1;
                            if (!wipe_dir) begin
                                if (rd_wipe == 20'd0) begin
                                    // 已经整幅是新图，下一帧正式切换
                                    rd_bank     <= rd_bank_new;
                                    rd_bank_new <= rd_bank_new;
                                    wr_bank     <= ~rd_bank_new;
                                    wipe_frm    <= 4'd0;
                                    ld_st       <= LD_SHOW;
                                end else if (rd_wipe <= 20'd60) begin
                                    rd_wipe <= 20'd0;
                                end else begin
                                    rd_wipe <= rd_wipe - 20'd60;
                                end
                            end else begin
                                if (rd_wipe >= 20'd720) begin
                                    rd_bank     <= rd_bank;      // WIPE 里 rd_bank 已经是新图
                                    rd_bank_new <= rd_bank;
                                    wr_bank     <= ~rd_bank;
                                    rd_wipe     <= 20'd720;
                                    wipe_frm    <= 4'd0;
                                    ld_st       <= LD_SHOW;
                                end else if (rd_wipe >= 20'd660) begin
                                    rd_wipe <= 20'd720;
                                end else begin
                                    rd_wipe <= rd_wipe + 20'd60;
                                end
                            end
                        end
                    end
                end

                LD_SHOW: begin
                    if (fade_lvl != 8'd255) fade_lvl <= 8'd255;
                    // 正常显示期间强制"不分界"：任何残留的 rd_wipe/rd_bank_new
                    // 都会让下半帧从另一块 bank 取数（那正是"横缝 + 下半重复"的成因）
                    rd_wipe     <= 20'd720;
                    rd_bank_new <= rd_bank;
                    // ---- 切图：唯一的入口是 nav_ctrl 的 step ----
                    //   手动（KEY1/KEY2）优先，自动（菜单 AUT）按档位计时，
                    //   两者都在 nav_ctrl 里判好，这里只负责"开始换图"。
                    //   先判 nav_step：即使同一拍缩放档位也变了，按键也不会被吞。
                    if (nav_step) begin
                        if (nav_step_prev)
                            img_idx <= (img_idx == 8'd0) ? (img_total_p - 8'd1)
                                                         : (img_idx - 8'd1);
                        else
                            img_idx <= (img_idx + 8'd1 >= img_total_p) ? 8'd0
                                                                        : (img_idx + 8'd1);
                        scale_d   <= dbg_scale;
                        // 安全护栏：加载前必须保证"写的那块 != 正在显示的那块"，
                        // 否则清屏会把用户正在看的图画黑（上板见过"半帧撕裂再黑屏"）。
                        if (USE_DBL[0] && (wr_bank == rd_bank)) wr_bank <= ~rd_bank;
                        load_cnt  <= 4'd0;     // 新一次切图，重新计数
                        ld_retry  <= 1'b0;     // 新一次切图，允许自愈重试
                        fin_dly   <= 13'd0;
                        // ★ 每张图都清屏，不再"上一张铺满就跳过"。
                        //   跳过的前提是"新图一定覆盖全部像素"，可一旦新图不满屏
                        //   （缩放档位 / 源图偏小 / 留边），旧图就会残留在新图后面。
                        //   写通路改造后清屏只要 ~35ms（518400 像素，写 FIFO 连续出队），
                        //   相对 1.3s 的读图可以忽略，所以无条件清屏最稳。
                        sc_clr    <= 1'b1;
                        clr_ok    <= 1'b0;
                        clr_wdog  <= 26'd0;
                        ld_st     <= LD_CLEAR;
                    end else if (dbg_scale != scale_d) begin
                        // 菜单“缩放”只在加载阶段生效，光改档位看不出变化。
                        // 这里检测到档位变化就重载当前这张（约 0.5s 后就能看到新效果），
                        // 否则用户会以为缩放坏了（上板反馈过“缩放无法使用”）。
                        scale_d   <= dbg_scale;
                        if (USE_DBL[0] && (wr_bank == rd_bank)) wr_bank <= ~rd_bank;
                        sc_clr    <= 1'b1;
                        clr_ok    <= 1'b0;
                        clr_wdog  <= 26'd0;
                        load_cnt  <= 4'd0;
                        ld_retry  <= 1'b0;
                        fin_dly   <= 13'd0;
                        ld_st     <= LD_CLEAR;
                    end
                end

                default: ld_st <= LD_WAIT;
            endcase
        end
    end


    // ------------------------------------------------------------------
    // 画面 + 菜单
    // ------------------------------------------------------------------
    // 丢像素计数（饱和到 4 位）：SHOW 态显示在数码管低半字节，
    // 用来判断黑线是不是"写 FIFO 满丢像素"造成的。每换一张图清零。
    reg [3:0] drop_cnt;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n)                    drop_cnt <= 4'd0;
        else if (sc_clr)               drop_cnt <= 4'd0;
        else if (fb_wr_drop && drop_cnt != 4'd15) drop_cnt <= drop_cnt + 4'd1;
    end

    // 数码管调试字（6 位显示，左两位 = dbg_ext[7:4]，右两位 = dbg_ext[3:0]）
    //   [7:4] 丢字计数（饱和 15），**任何状态都显示**，正常应为 0
    //   [3:0] {ld_st[2:0], sd_ready}：
    //         1=WAIT 3=CLEAR 5=ARM 7=LOAD 9=SHOW（sd_ready=1 时都是奇数）
    wire        trk_bad;           // 曲目头不是 RIFF（SD 卡镜像/参数不匹配）
    wire [15:0] wav_hdr;           // 曲目首扇区第一个字（调试显示）
    // ------------------------------------------------------------------
    // SD 兜底重启
    //   上电后一直停在 LD_WAIT（挂载/扫描没走完），或单次传输卡住 >335ms，
    //   就把 sd_ctrl_top / sd_arb / fat_mnt / fat_scan 整段复位重来。
    //   只在 LD_WAIT（还没装过第一张图）时动手，不会打断正在读图的过程。
    //   最多重试 3 次；之后保持现状，数码管上能看到卡在哪一步。
    // ------------------------------------------------------------------
    reg [22:0] sbusy_tmr;
    always @(posedge clk_sd or negedge rst_n) begin
        if (!rst_n)                       sbusy_tmr <= 23'd0;
        else if (!arb_busy)               sbusy_tmr <= 23'd0;
        else if (sbusy_tmr != 23'h7FFFFF) sbusy_tmr <= sbusy_tmr + 23'd1;
    end
    wire sd_bus_stuck = (sbusy_tmr == 23'h7FFFFF);   // 335ms

    reg [26:0] boot_tmr;
    reg [1:0]  sd_retry;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            boot_tmr  <= 27'd0;
            sd_retry  <= 2'd0;
            sd_reinit <= 1'b0;
        end else if (sd_reinit) begin
            // 复位保持约 1.4ms 再放，让 sd_init 从 CMD0 重新走
            if (boot_tmr != 27'h1FFFF) boot_tmr <= boot_tmr + 27'd1;
            else begin
                boot_tmr  <= 27'd0;
                sd_reinit <= 1'b0;
            end
        end else if (reinit_pulse) begin
            // ★ 加载超时/读失败后的自愈：由 FSM 打一拍，这里统一拉 sd_reinit。
            //   （sd_reinit 只在这一个 always 块里赋值，避免多驱动）
            sd_reinit <= 1'b1;
            boot_tmr  <= 27'd0;
        end else if (ld_st != LD_WAIT) begin
            boot_tmr <= 27'd0;
        end else if (sd_bus_stuck) begin
            if (sd_retry != 2'd3) begin
                sd_retry  <= sd_retry + 2'd1;
                sd_reinit <= 1'b1;
                boot_tmr  <= 27'd0;
            end
        end else if (boot_tmr != 27'h5FFFFFF) begin
            boot_tmr <= boot_tmr + 27'd1;            // 约 2.7s
        end else if (sd_retry != 2'd3) begin
            sd_retry  <= sd_retry + 2'd1;
            sd_reinit <= 1'b1;
            boot_tmr  <= 27'd0;
        end
    end

    // ------------------------------------------------------------------
    // 数码管（6 位，左->右）：
    //   读图进度(00~99) / 静止时"加载次数|丢字" | 图片数 | {ld_st,sd_ready}
    //   | 切图次数 | 上次切图耗时（0.447s 一格，F=6.7s 以上）
    //   静止正常: 1 0 4 9 1 3   （1 次加载 / 0 丢字 / 4 张 / SHOW / 1 次切图 / 1.3s）
    //   读图中  : 4 7 4 7 1 0   （47% / 4 张 / LOAD / 1 次切图 / …）
    //   扫描错  : .. F 3 ..     挂载错: .. E 1 ..
    //
    // ★ 进度只用 9 个寄存器：拿 sw_tmr[19] 的上升沿（2^20/37.5MHz = 28ms）
    //   让两位 BCD 加 1，2.77s 走满 100%。sw_tmr 只由"切图那一拍"清零，
    //   加载过程中绝不清零 —— 所以进度条不可能自己重头再走一遍。
    // ------------------------------------------------------------------
    wire        ld_busy = (ld_st == LD_CLEAR) || (ld_st == LD_ARM) ||
                          (ld_st == LD_LOAD);

    reg        wd19_d;
    reg  [3:0] prog_t, prog_u;               // 十位 / 个位（BCD）
    wire       prog_tick = sw_tmr[19] & ~wd19_d;
    wire       prog_top  = (prog_t == 4'd9) && (prog_u == 4'd9);

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            wd19_d <= 1'b0;
            prog_t <= 4'd0;
            prog_u <= 4'd0;
        end else begin
            wd19_d <= sw_tmr[19];
            if (sw_rst) begin
                // ★ 只在"开始换图"那一拍清零。
                //   旧版写的是 "sc_clr || ld_wdog==0"：ld_wdog 在 LD_LOAD 里
                //   一旦没人推进就会一直走到 2^28 回绕成 0，于是进度条被
                //   半路清零重走 —— 上板看到的"0→99 反复"就是它。
                prog_t <= 4'd0;
                prog_u <= 4'd0;
            end else if (prog_tick && ld_busy && !prog_top) begin
                // ★ 封顶必须是"十位个位都是 9 就整条停住"。
                //   旧写法只判了个位：到 99 后个位归 0、十位不再加 -> 掉回 90，
                //   再数到 99，每 126ms 循环一次，看起来就是"98/99 来回跳、卡住不动"。
                if (prog_u == 4'd9) begin
                    prog_u <= 4'd0;
                    prog_t <= prog_t + 4'd1;
                end else begin
                    prog_u <= prog_u + 4'd1;
                end
            end
        end
    end

    //   加载中：读图进度；静止：最左位 = 本次切图加载了几次，
    //   第二位 = 出错时 reader 卡在哪个状态（0 = 本次没出错）
    wire [7:0]  dbg_head = ld_busy ? {prog_t, prog_u}
                                   : {load_cnt, rdr_err_st};

    // 6 位：左两位 = 读图进度（加载中）/ 加载次数+出错状态（静止）
    //       中间两位 = 图片数（十六进制）   右边两位 = 音乐数（十六进制）
    wire [23:0] dbg_ext = (scan_err != 8'd0) ? {dbg_head, 4'hF, scan_err, 8'h00}
                        : (mnt_err  != 8'd0) ? {dbg_head, 4'hE, mnt_err, 8'h00}
                        : { dbg_head, img_total_p[7:0], 4'd0, mus_total_p };

    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire [7:0]  dbg_prog;

    top_osd_demo #(
        .HACTIVE(HACTIVE), .HTOTAL(HTOTAL), .HSA(HSA), .HBP(HBP), .HFP(HFP),
        .VACTIVE(VACTIVE), .VTOTAL(VTOTAL), .VSA(VSA), .VBP(VBP), .VFP(VFP),
        .PX0(340), .PY0(30), .PW(600), .PH(660),
        .HOLD_FRAMES(75),
        .KEY_CLK_HZ(37_500_000),
        .USE_EXT(1),
        .MUS_NUM(6)
    ) u_core (
        .clk(clk_pix), .rst_n(rst_n),
        // 按键分配（按板上丝印确认过）：
        //   key1(A2)=上  key2(C1)=列表  key3(B1)=菜单  key4(B2)=下
        //   key_in 位序 = {OK, DOWN, UP, LIST}
        .key({key3, key4, key1, key2}),      // {OK=key3, DOWN=key4, UP=key1, LIST=key2}
        .rgb_out(rgb), .hs_out(hs), .vs_out(vs), .de_out(de),
        .x_out(x), .y_out(y),
        .menu_open(menu_open), .dbg_item(dbg_item), .dbg_val(dbg_val),
        .dbg_prog(dbg_prog), .dbg_effect(dbg_effect), .dbg_scale(dbg_scale),
        .dbg_vol(dbg_vol),
        .dbg_mus(dbg_mus), .dbg_auto(dbg_auto),
        .dbg_hold(dbg_hold), .dbg_style(dbg_style),
        .nav_next(nav_next), .nav_prev(nav_prev),
        .seg_sel(seg_sel), .seg_data(seg_data),
        .img_changed(img_changed),
        .fade_lvl(fade_lvl),
        .ext_rgb(fb_rgb),
        .raw_de(raw_de), .raw_x(raw_x), .raw_y(raw_y),
        .dbg_ext(dbg_ext), .dbg_hdr(wav_hdr),
        .aud_samp(aud_left[23:8]), .aud_samp_v(aud_valid),
        .aud_meter_en(1'b1),         // 总开关；实际显示由菜单 VU（默认 OFF）控制
        .mus_total(mus_total_p), .mus_name(mus_name_p),
        .media_alert(media_alert)
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

    wire        tone_valid;
    wire [23:0] tone_l, tone_r;
    wire [7:0]  tone_lvl;

    wire        wav_valid;
    wire [23:0] wav_l, wav_r;
    wire [7:0]  wav_lvl;

    tone_gen #(.CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)) u_tone (
        .clk       (clk_pix),
        .rst       (~rst_n),
        .note_idx  (img_idx),
        .vol       (dbg_vol),
        .mute      (dbg_mus != 3'd1),        // 只有"内置音阶"档才响
        .aud_valid (tone_valid),
        .aud_left  (tone_l),
        .aud_right (tone_r),
        .env_out   (tone_lvl)
    );

    // 菜单 MUS：2..5 -> SD 曲目 1..4
    wire [2:0] wav_trk = (dbg_mus >= 3'd2) ? (dbg_mus - 3'd1) : 3'd0;

    wav_player #(
        .TRK_NUM(6),
        .CLK_HZ(37_500_000), .SAMPLE_HZ(48_000)
    ) u_wav (
        .clk     (clk_pix),
        .clk_sd  (clk_sd),
        .rst     (~rst_n),
        .track   (wav_trk),
        .vol     (dbg_vol),
        .fat_lba (fat_lba),
        .data_lba(data_lba),
        .spc_log2(spc_log2),
        .tbl_req (mus_tbl_req),
        .tbl_rec (mus_tbl_rec),
        .tbl_done(mus_tbl_done),
        .tbl_data(mus_tbl_data),
        .s_req   (wav_req),
        .s_sec   (wav_sec),
        .s_busy  (wav_busy),
        .s_val   (wav_val),
        .s_data  (wav_data),
        .aud_valid(wav_valid),
        .aud_left (wav_l),
        .aud_right(wav_r),
        .level    (wav_lvl),
        .trk_bad  (trk_bad),
        .trk_name (wav_trk_name),
        .dbg_hdr  (wav_hdr)
    );

    // 音源选择：有 WAV 曲目就放 WAV，否则放内置音阶
    assign aud_valid = (wav_trk != 3'd0) ? wav_valid : tone_valid;
    assign aud_left  = (wav_trk != 3'd0) ? wav_l     : tone_l;
    assign aud_right = (wav_trk != 3'd0) ? wav_r     : tone_r;
    assign aud_lvl   = (wav_trk != 3'd0) ? wav_lvl   : tone_lvl;

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
