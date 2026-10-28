// ============================================================================
//  top_osd_demo.v —— 双图 + 转场 + 参数 + 菜单 的整合演示顶层
//
//  像素通路：
//     color_bar_hd  ─┐
//                    ├─> transition ─> param_apply ─> 延时2拍 ─┐
//     test_pattern_b ┘                                        ├─> alpha_blend ─> rgb_out
//     osd_menu ───────────────────────────────────────────────┘
//
//  菜单开合只影响叠加层，视频通路每拍照常输出。
// ============================================================================
`timescale 1ns / 1ps

module top_osd_demo #(
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
    parameter integer PX0     = 340,
    parameter integer PY0     = 30,
    parameter integer PW      = 600,
    parameter integer PH      = 660,
    parameter integer HOLD_FRAMES = 150,        // 每张停留帧数
    parameter integer KEY_CLK_HZ  = 75_000_000, // 仅仿真时调小以加速
    parameter integer USE_EXT     = 0,          // 1=A 路视频改用外部输入（SDRAM 图）
    parameter integer MUS_NUM     = 4           // SD 曲目数（菜单 MUS 项上限）
)(
    input  wire        clk,          // 像素时钟 75MHz
    input  wire        rst_n,
    input  wire [3:0]  key,          // {OK, DOWN, UP, MENU}，低有效

    output wire [23:0] rgb_out,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [11:0] x_out,
    output wire [11:0] y_out,

    output wire        menu_open,
    output wire [2:0]  dbg_item,
    output wire [3:0]  dbg_val,
    output wire [7:0]  dbg_prog,
    output wire [1:0]  dbg_effect,
    output wire [1:0]  dbg_scale,
    output wire [3:0]  dbg_vol,      // 菜单音量 0..10（给 tone_gen）
    output wire [2:0]  dbg_mus,      // 菜单 MUS：0=关 1=内置 2..=SD 曲目
    output wire        dbg_auto,     // 1=自动轮播
    output wire [2:0]  dbg_hold,     // 切屏间隔档位
    output wire        dbg_style,    // 0=条形 1=圆形
    output wire        nav_next,     // KEY2（非菜单态）：下一张
    output wire        nav_prev,     // KEY1（非菜单态）：上一张

    output wire [5:0]  seg_sel,
    output wire [7:0]  seg_data,

    input  wire        img_changed,  // 换图脉冲（双缓冲换 bank 时给一拍）
    input  wire [7:0]  fade_lvl,     // 转场淡入淡出：255=正常亮度 0=全黑
    input  wire [15:0] ext_rgb,      // 外部视频（RGB565，黑边=0）
    output wire        raw_de,       // 未延迟的 de / 坐标，给帧缓存读侧用
    output wire [11:0] raw_x,
    output wire [11:0] raw_y,        // 帧内行号 0..VTOTAL-1
    input  wire [23:0] dbg_ext,      // 调试字（6 个半字节，显示在数码管）
    input  wire [15:0] dbg_hdr,      // 曲目首扇区第一个 16bit 字（trk_bad 时显示）
    input  wire signed [15:0] aud_samp,  // 48kHz 采样（给频谱分析）
    input  wire        aud_samp_v,       // 采样有效
    input  wire        aud_meter_en,     // 1 = 显示频谱
    input  wire [3:0]  mus_total,        // FAT 目录里的 WAV 数量（0..6）
    input  wire [63:0] mus_name,         // 当前曲目 8.3 名字
    input  wire        media_alert       // 1 = 没有可用图片
);

    wire rst = ~rst_n;

    // 行/场计数器含消隐，换算成"活动区坐标"再送菜单与输出
    localparam integer HSTART = HSA + HBP;
    localparam integer VSTART = VSA + VBP;

    wire [11:0] act_x;
    wire [11:0] act_y;

    // ------------------------------------------------------------------
    // 两路测试图（同一套时序）
    // ------------------------------------------------------------------
    wire [7:0]  a_r, a_g, a_b;
    wire        bg_hs, bg_vs, bg_de;
    wire [11:0] bg_x, bg_y;

    color_bar_hd #(
        .HACTIVE(HACTIVE), .HTOTAL(HTOTAL), .HSA(HSA), .HBP(HBP), .HFP(HFP),
        .VACTIVE(VACTIVE), .VTOTAL(VTOTAL), .VSA(VSA), .VBP(VBP), .VFP(VFP)
    ) u_bar (
        .clk(clk), .rst(rst),
        .hs(bg_hs), .vs(bg_vs), .de(bg_de),
        .rgb_r(a_r), .rgb_g(a_g), .rgb_b(a_b),
        .o_hcnt(bg_x), .o_vcnt(bg_y)
    );

    assign act_x = bg_x - HSTART[11:0];
    assign act_y = bg_y - VSTART[11:0];

    wire [23:0] b_rgb;
    test_pattern_b #(.HACTIVE(HACTIVE), .VACTIVE(VACTIVE)) u_pat_b (
        .clk(clk), .rst(rst), .x(act_x), .y(act_y), .rgb(b_rgb)
    );

    // ------------------------------------------------------------------
    // A 路视频：USE_EXT=1 时用外部输入（SDRAM 帧缓存的图片输出）
    // ------------------------------------------------------------------
    wire [23:0] ext_rgb24 = {ext_rgb[15:11], 3'b000,
                             ext_rgb[10:5],  2'b00,
                             ext_rgb[4:0],   3'b000};
    wire [23:0] base_a = USE_EXT ? ext_rgb24 : {a_r, a_g, a_b};

    // ------------------------------------------------------------------
    // 菜单
    // ------------------------------------------------------------------
    wire [3:0] k_press, k_rep;
    key_ctrl #(.CLK_HZ(KEY_CLK_HZ)) u_key (
        .clk(clk), .rst(rst), .key_in(key),
        .press(k_press), .rep(k_rep)
    );

    wire        osd_on;
    wire [23:0] osd_rgb;
    wire [3:0]  osd_alpha;
    wire [1:0]  cfg_trans;
    wire [3:0]  cfg_bright, cfg_contrast, cfg_vol;
    wire [1:0]  cfg_scale;
    wire [2:0]  cfg_mus; wire cfg_meter, cfg_sub, cfg_auto, cfg_commit;
    wire [2:0]  cfg_hold; wire cfg_style;

    osd_menu #(
        .HACTIVE(HACTIVE), .VACTIVE(VACTIVE),
        .PX0(PX0), .PY0(PY0), .PW(PW), .PH(PH), .MUS_NUM(MUS_NUM)
    ) u_menu (
        .clk(clk), .rst(rst),
        .x(act_x), .y(act_y), .de(bg_de),
        .key_menu(k_press[0]),
        .key_up  (k_press[1] | k_rep[1]),
        .key_down(k_press[2] | k_rep[2]),
        .key_ok  (k_press[3] | k_rep[3]),
        .osd_on(osd_on), .osd_rgb(osd_rgb), .osd_alpha(osd_alpha),
        .menu_open(menu_open),
        .dbg_item(dbg_item), .dbg_val(dbg_val),
        .cfg_commit(cfg_commit),
        .cfg_trans(cfg_trans), .cfg_bright(cfg_bright), .cfg_contrast(cfg_contrast),
        .cfg_scale(cfg_scale), .cfg_mus(cfg_mus), .cfg_vol(cfg_vol),
        .cfg_auto(cfg_auto),
        .nav_next(), .nav_prev(),     // 改由本文件直接产生，见下面
        .cfg_meter(cfg_meter),
        .cfg_sub(cfg_sub),
        .cfg_hold(cfg_hold), .cfg_style(cfg_style),
        .mus_total(mus_total), .mus_name(mus_name), .alert(media_alert)
    );

    // ------------------------------------------------------------------
    // 图片切换：只响应"按下那一下"，**不用长按连发**
    //   菜单里的上下移动需要连发（快速翻列表），但换图不能：
    //   key_ctrl 的 rep 是 100ms 一次，长按 1 秒会连发 10 次，
    //   每一次都会把刚启动的加载打断、进度归零，
    //   上板表现就是"进度 0→99 反复重来、一次切图要几十秒"。
    // ------------------------------------------------------------------
    assign nav_next = ~menu_open & k_press[2];   // KEY2：下一张
    assign nav_prev = ~menu_open & k_press[1];   // KEY1：上一张

    // ------------------------------------------------------------------
    // 参数影子寄存器：按键随时可改，帧首才生效
    // ------------------------------------------------------------------
    wire [1:0] ef_trans;
    wire [3:0] ef_bright, ef_contrast, ef_vol;
    wire [1:0] ef_scale;
    wire [2:0] ef_mus;
    wire       ef_auto;
    wire       ef_meter;
    wire [2:0] ef_hold;
    wire       ef_style;
    wire [3:0] cfg_ver;

    cfg_latch u_cfg (
        .clk(clk), .rst(rst), .commit(cfg_commit),
        .in_trans(cfg_trans), .in_bright(cfg_bright), .in_contrast(cfg_contrast),
        .in_scale(cfg_scale), .in_mus(cfg_mus), .in_vol(cfg_vol),
        .in_auto(cfg_auto),
        .in_meter(cfg_meter),
        .in_hold(cfg_hold), .in_style(cfg_style),
        .trans(ef_trans), .bright(ef_bright), .contrast(ef_contrast),
        .scale(ef_scale), .mus(ef_mus), .vol(ef_vol), .meter(ef_meter),
        .auto_en(ef_auto), .hold(ef_hold), .style(ef_style),
        .ver(cfg_ver)
    );

    // ------------------------------------------------------------------
    // 转场
    // ------------------------------------------------------------------
    wire        frame_tick = (act_x == 12'd0) && (act_y == 12'd0);
    wire [7:0]  trans_prog;
    wire        trans_swap;

    // 换图脉冲要撑到下一个 frame_tick（一帧 90 万拍，1 拍脉冲必然错过）
    reg [3:0] tg_win;
    always @(posedge clk or posedge rst) begin
        if (rst)                tg_win <= 4'd0;
        else if (img_changed)   tg_win <= 4'd8;
        else if (tg_win != 4'd0) tg_win <= tg_win - 4'd1;
    end
    wire trig_evt = (tg_win != 4'd0);

    auto_transition #(
        .HOLD_FRAMES(HOLD_FRAMES),
        .RUN_FRAMES (USE_EXT ? 16 : 32),    // 淡入 16 帧 ≈ 0.5s
        .ONESHOT    (USE_EXT ? 1 : 0)       // 播放真实图片时不做 A/B 周期交替
    ) u_auto (
        .clk(clk), .rst(rst),
        .frame_tick(frame_tick),
        .trig(USE_EXT ? trig_evt : 1'b0),
        .pre_clr(USE_EXT ? img_changed : 1'b0),
        .effect(ef_trans),
        .prog(trans_prog),
        .swap(trans_swap)
    );

    // USE_EXT=1（真实图片播放）：
    //   B 源原来是 test_pattern_b 的彩条，A/B 交替会让每张图之后插入一段彩条，
    //   所以这里把转场改成"黑 -> 新图"的单次淡入：换图时从黑淡入，既保留转场特效
    //   又不会遮挡画面。非 USE_EXT（纯演示）保持原来的 A/B 交替。
    wire [23:0] src_a = USE_EXT ? 24'h000000 : (trans_swap ? b_rgb : base_a);
    wire [23:0] src_b = USE_EXT ? base_a     : (trans_swap ? base_a : b_rgb);

    wire [23:0] trans_rgb;
    wire [7:0] prog_use = USE_EXT ? fade_lvl : trans_prog;
    wire [1:0] eff_use  = USE_EXT ? 2'd0     : ef_trans;   // USE_EXT 固定走 FADE 通道

    transition #(.HACTIVE(HACTIVE)) u_trans (
        .clk(clk), .rst(rst),
        .rgb_a(src_a), .rgb_b(src_b),
        .x(act_x), .effect(eff_use), .prog(prog_use),
        .rgb_out(trans_rgb)
    );

    // 真实图片播放时，转场由帧缓存/状态机完成：
    //   FADE 用 fade_lvl 控制亮度；SLIDE/WIPE 在帧缓存里按分界选 bank；
    //   CUT 直接硬切。所以这一级只在"确实要减弱亮度"时才经过 mix8，
    //   否则 fade_lvl=255 的 mix8 会做 b*255/256（0.4% 无谓掉亮）。
    wire [23:0] trans_use = (USE_EXT && (fade_lvl == 8'd255)) ? base_a : trans_rgb;

    // ------------------------------------------------------------------
    // 亮度 / 对比度
    // ------------------------------------------------------------------
    wire [23:0] adj_rgb;
    // USE_EXT（真实图片播放）：用"淡出到黑 -> 淡入新图"的转场。
    //   a 恒为黑、b 为图片，mix8 = b*fade_lvl/256：
    //   fade_lvl=255 正常显示、=0 全黑。换 bank 发生在全黑那一刻，看不见。
    //   原来的 A/B 交替（彩条）和推入分界都不再使用。
    param_apply u_param (
        .rgb_in(trans_use),
        .bright(ef_bright), .contrast(ef_contrast),
        .rgb_out(adj_rgb)
    );

    // ------------------------------------------------------------------
    // 打 2 拍，与菜单输出对齐
    // ------------------------------------------------------------------
    // transition 内部 2 级流水，param 之后再打 2 拍 -> 视频共晚 4 拍
    reg [23:0] vd1, vd2;
    reg        hsd1, hsd2, hsd3, hsd4;
    reg        vsd1, vsd2, vsd3, vsd4;
    reg        ded1, ded2, ded3, ded4;
    reg [11:0] xd1, xd2, xd3, xd4;
    reg [11:0] yd1, yd2, yd3, yd4;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vd1 <= 24'd0; vd2 <= 24'd0;
            hsd1 <= 1'b0; hsd2 <= 1'b0; hsd3 <= 1'b0; hsd4 <= 1'b0;
            vsd1 <= 1'b0; vsd2 <= 1'b0; vsd3 <= 1'b0; vsd4 <= 1'b0;
            ded1 <= 1'b0; ded2 <= 1'b0; ded3 <= 1'b0; ded4 <= 1'b0;
            xd1 <= 12'd0; xd2 <= 12'd0; xd3 <= 12'd0; xd4 <= 12'd0;
            yd1 <= 12'd0; yd2 <= 12'd0; yd3 <= 12'd0; yd4 <= 12'd0;
        end else begin
            vd1 <= adj_rgb;   vd2 <= vd1;
            hsd1 <= bg_hs;    hsd2 <= hsd1;    hsd3 <= hsd2;    hsd4 <= hsd3;
            vsd1 <= bg_vs;    vsd2 <= vsd1;    vsd3 <= vsd2;    vsd4 <= vsd3;
            ded1 <= bg_de;    ded2 <= ded1;    ded3 <= ded2;    ded4 <= ded3;
            xd1 <= act_x;     xd2 <= xd1;      xd3 <= xd2;      xd4 <= xd3;
            yd1 <= act_y;     yd2 <= yd1;      yd3 <= yd2;      yd4 <= yd3;
        end
    end

    // osd_menu 输出比输入晚 3 拍，再补 1 拍与视频（4 拍）对齐
    reg [23:0] osd_rgb_d;
    reg [3:0]  osd_alpha_d;
    reg        osd_on_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            osd_rgb_d   <= 24'd0;
            osd_alpha_d <= 4'd0;
            osd_on_d    <= 1'b0;
        end else begin
            osd_rgb_d   <= osd_rgb;
            osd_alpha_d <= osd_alpha;
            osd_on_d    <= osd_on;
        end
    end

    // 先叠菜单（alpha 混合），再叠音频电平表
    wire [23:0] blend_menu;

    alpha_blend u_blend (
        .vid_rgb (vd2),
        .osd_rgb (osd_rgb_d),
        .alpha   (osd_alpha_d),
        .out_rgb (blend_menu)
    );

    // ------------------------------------------------------------------
    // 音频频谱（扩展要求 5）
    //   ★ 这里以前是"总电平的瀑布图"：128 列其实是同一个标量的历史，
    //     看起来整排一起起伏。现在换成 spectrum.v 的 **32 段频段能量**，
    //     每根柱对应 50Hz~16kHz 的一个对数频段，各段能量不同 ->
    //     每根柱独立跳动（这才是频谱仪的观感）。
    //   32 段 x 32px = 1024 宽，叠在图片下部（y 468..579）。
    // ------------------------------------------------------------------
    wire        m_on;
    wire [23:0] m_rgb;
    wire [3:0]  m_alpha;
    wire [255:0] spec_bars;          // 32 段 x 8bit

    spectrum #(.NB(32), .BLOCK(1024), .DECAY(6)) u_spec (
        .clk(clk), .rst(rst),
        .sample(aud_samp), .sample_valid(aud_samp_v),
        .frame_start(frame_tick),
        .bars(spec_bars)
    );

    audio_meter #(
        .X0(128), .Y0(468), .BARW(32), .NBAR(32), .MAXH(112)
    ) u_meter (
        .clk(clk), .rst(rst),
        .x(xd1), .y(yd1),              // 早三拍，模块内部三级流水后与视频对齐
        .bars(spec_bars),
        .enable(aud_meter_en & ef_meter & ~menu_open),
        .style(ef_style),
        .on(m_on), .rgb(m_rgb), .alpha(m_alpha)
    );

    // ------------------------------------------------------------------
    // 叠加：电平表画在**图片上**，半透明（75% 电平表 + 25% 画面）。
    //   固定 3:1 混合可以只用移位+加法：out = v/4 + m/2 + m/4，零乘法器。
    // ------------------------------------------------------------------
    function [7:0] mix_meter;
        input [7:0] v;
        input [7:0] m;
        begin
            mix_meter = {2'b00, v[7:2]} + {1'b0, m[7:1]} + {2'b00, m[7:2]};
        end
    endfunction

    assign rgb_out = m_on
                   ? { mix_meter(blend_menu[23:16], m_rgb[23:16]),
                       mix_meter(blend_menu[15:8],  m_rgb[15:8]),
                       mix_meter(blend_menu[7:0],   m_rgb[7:0])  }
                   : blend_menu;

    assign hs_out = hsd4;
    assign vs_out = vsd4;
    assign de_out = ded4;
    assign x_out  = xd4;
    assign y_out  = yd4;

    assign dbg_prog   = trans_prog;
    assign dbg_effect = ef_trans;
    assign dbg_scale  = ef_scale;
    assign dbg_vol    = ef_vol;
    assign dbg_mus    = ef_mus;
    assign dbg_auto   = ef_auto;
    assign dbg_hold   = ef_hold;
    assign dbg_style  = ef_style;

    assign raw_de = bg_de;
    assign raw_x  = act_x;
    assign raw_y  = bg_y;

    // ------------------------------------------------------------------
    seg7 #(.CLK_HZ(KEY_CLK_HZ)) u_seg (
        .clk     (clk),
        .rst_n   (rst_n),
        // seg7 的 dsel=0 对应最左边一位，而取的是 value[3:0]，所以这里反着拼：
        //   左->右 = 读通路丢字 | 图片数 | {ld_st,sd_ready} | 挂载状态 | 扫描状态
        //   6 位数字；正常: 0 0 3 9 0 8（丢字必须一直是 00）
        .value   ({dbg_ext[3:0], dbg_ext[7:4], dbg_ext[11:8], dbg_ext[15:12],
                   dbg_ext[19:16], dbg_ext[23:20]}),
        .dp_mask ({menu_open, 5'b00000}),
        .seg_sel (seg_sel),
        .seg_data(seg_data)
    );

endmodule
