// ============================================================================
//  osd_menu.v —— 调试菜单：全屏半透明遮罩 + 居中面板
//
//  三页：
//    page 0  设置页   [IMG] 亮度 对比度 缩放模式 音量 VU SUB
//    page 1  音乐列表 OFF / GEN / T1..Tn（KEY3 从非菜单态直接进）
//    page 2  图片子菜单 AUT（轮播开关）/ 切屏效果（FADE/SLIDE/WIPE/CUT）
//
//  纯像素域、纯坐标实时生成：不读帧缓存、不占 SDRAM 带宽。
//  四级流水（区域 -> 地址 -> 字模 -> 合成），输出比输入 x/y 晚 3 个像素。
//
//  按键：KEY4 开/关（任何页都直接关），KEY1/KEY2 上下，KEY3 确认/改值
// ============================================================================
`timescale 1ns / 1ps

module osd_menu #(
    parameter integer HACTIVE = 1280,
    parameter integer VACTIVE = 720,
    parameter integer PX0 = 360,      // 面板左上角
    parameter integer PY0 = 110,
    parameter integer PW  = 560,
    parameter integer PH  = 500,
    parameter integer MUS_NUM = 4     // 兼容保留（实际曲目数由 mus_total 给）
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        de,

    input  wire        key_menu,
    input  wire        key_up,
    input  wire        key_down,
    input  wire        key_ok,

    // ---- FAT 扫描结果（曲目数 / 当前曲目名 / 无图片告警）----
    input  wire [3:0]  mus_total,
    input  wire [63:0] mus_name,
    input  wire        alert,

    output reg         osd_on,
    output reg  [23:0] osd_rgb,
    output reg  [3:0]  osd_alpha,     // 0..8，0=透明 8=不透明

    output wire        menu_open,
    output wire [2:0]  dbg_item,
    output wire [3:0]  dbg_val,
    output reg         cfg_commit,    // 帧首单拍，供下游统一提交参数

    output reg  [1:0]  cfg_trans,
    output reg  [3:0]  cfg_bright,
    output reg  [3:0]  cfg_contrast,
    output reg  [1:0]  cfg_scale,
    output reg  [2:0]  cfg_mus,     // 0=关 1=内置音阶 2..=SD 曲目
    output reg         cfg_auto,    // 1=图片自动轮播
    output wire        nav_next,    // 非菜单态下 KEY1：下一张
    output wire        nav_prev,    // 非菜单态下 KEY2：上一张
    output wire        page_mus,    // 当前是否停在音乐列表页（调试用）
    output reg  [3:0]  cfg_vol,
    output reg         cfg_meter,    // 1 = 显示音频电平表（频谱）
    output reg         cfg_sub,      // 1 = 显示底部滚动字幕
    output reg  [2:0]  cfg_hold,     // 切屏间隔档位 0..4 -> 3/5/8/15/30 秒
    output reg         cfg_style     // 0 = 底部条形  1 = 圆形中央
);

    // ------------------------------------------------------------------
    // 配色
    // ------------------------------------------------------------------
    localparam [23:0] C_MASK   = 24'h00_00_00;
    localparam [23:0] C_PANEL  = 24'h14_18_20;
    localparam [23:0] C_BORDER = 24'h4A_A8_E0;
    localparam [23:0] C_TITLE  = 24'hFF_C8_50;
    localparam [23:0] C_LABEL  = 24'hC8_D0_D8;
    localparam [23:0] C_VALUE  = 24'hFF_FF_FF;
    localparam [23:0] C_HLBG   = 24'h2A_5A_9A;
    localparam [23:0] C_HINT   = 24'h8A_96_A4;

    // ------------------------------------------------------------------
    // 菜单状态
    // ------------------------------------------------------------------
    reg        open;
    reg [1:0]  page;               // 0=设置页 1=音乐列表 2=图片子菜单
    reg [2:0]  item;
    reg [1:0]  v_trans;
    reg [3:0]  v_bright;
    reg [3:0]  v_contrast;
    reg [1:0]  v_scale;
    reg [2:0]  v_mus;
    reg [3:0]  v_vol;
    reg        v_meter;
    reg        v_sub;              // 字幕开关（与频谱互不影响）
    reg        v_auto;             // 轮播开关（默认关：上电不自动转场）
    reg [2:0]  v_hold;             // 切屏间隔 0..4（3/5/8/15/30 秒）
    reg        v_style;            // 0=底部条形 1=圆形中央

    // 当前光标项的取值（只用于数码管/调试观测）
    wire [3:0] cur_val = (page == 2'd1) ? {1'b0, v_mus} :
                         (page == 2'd2) ? ((item == 3'd0) ? {3'b000, v_auto}    :
                                           (item == 3'd1) ? {2'b00, v_trans}   :
                                                            {1'b0, v_hold})    :
                         (page == 2'd3) ? ((item == 3'd0) ? {3'b000, v_meter}
                                                          : {3'b000, v_style}) :
                         (item == 3'd1) ? v_bright            :
                         (item == 3'd2) ? v_contrast          :
                         (item == 3'd3) ? {2'b00, v_scale}    :
                         (item == 3'd4) ? v_vol               :
                         (item == 3'd5) ? {3'b000, v_meter}   :
                         (item == 3'd6) ? {3'b000, v_sub}     : 4'd0;

    assign menu_open = open;
    assign dbg_item  = item;
    assign dbg_val   = cur_val;

    // 面板当前页的最大行号
    wire [2:0] row_max = (page == 2'd1) ? ({1'b0, mus_total} + 3'd1) :
                         (page == 2'd2) ? 3'd2 :
                         (page == 2'd3) ? 3'd1 : 3'd6;

    // 非菜单态下，KEY1/KEY2 直接切图（给上层用）
    // 非菜单态：KEY1=上一张(up) KEY2=下一张(down)，与菜单里上下移动同向
    assign nav_next = ~open & key_down;
    assign nav_prev = ~open & key_up;
    assign page_mus = open & (page == 2'd1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            open       <= 1'b0;
            page       <= 2'd0;
            item       <= 3'd0;
            v_trans    <= 2'd0;
            v_bright   <= 4'd10;
            v_contrast <= 4'd10;
            v_scale    <= 2'd0;
            v_mus      <= 3'd0;      // 默认：OFF（上电不自动放内置音乐）
            v_vol      <= 4'd6;
            v_meter    <= 1'b0;      // 默认：频谱关
            v_sub      <= 1'b1;      // 默认：字幕开
            v_auto     <= 1'b0;      // 默认：不自动轮播（上电不转场）
            v_hold     <= 3'd1;      // 默认：5 秒
            v_style    <= 1'b0;      // 默认：底部条形
        end else begin
            // ============================================================
            //  统一的按键语义（任何界面都一样）：
            //    KEY1 = 上：菜单外上一张 / 菜单内光标上移
            //    KEY2 = 下：菜单外下一张 / 菜单内光标下移
            //    KEY3 = 进：菜单外打开功能菜单 / 菜单内确认·进入·改值
            //    KEY4 = 退：菜单外打开音乐列表 / 菜单内关闭（任何页一次退出）
            // ============================================================
            if (key_menu) begin
                // ---- KEY4 ----
                if (open) begin
                    open <= 1'b0;                // 菜单内：关闭
                end else begin
                    open <= 1'b1;                // 菜单外：打开音乐列表
                    page <= 2'd1;
                    // 光标停在当前曲目上；卡换了/曲目变少时夹回列表内
                    item <= ({1'b0, v_mus} > ({1'b0, mus_total} + 4'd1))
                            ? 3'd0 : v_mus;
                end
            end else if (key_ok) begin
                // ---- KEY3 ----
                if (!open) begin
                    open <= 1'b1;                // 菜单外：打开功能菜单（设置页）
                    page <= 2'd0;
                    item <= 3'd0;
                end else if (page == 2'd1) begin
                    v_mus <= item;                // 0=OFF 1=GEN 2..=T1..
                    open  <= 1'b0;                // 选完自动关闭
                end else if (page == 2'd2) begin
                    if (item == 3'd0)      v_auto  <= ~v_auto;             // 轮播开关
                    else if (item == 3'd1) v_trans <= (v_trans == 2'd3) ? 2'd0
                                                                       : v_trans + 2'd1;
                    else                   v_hold  <= (v_hold == 3'd4) ? 3'd0
                                                                       : v_hold + 3'd1;
                end else if (page == 2'd3) begin
                    if (item == 3'd0) v_meter <= ~v_meter;                 // 频谱开关
                    else              v_style <= ~v_style;                 // 条形 / 圆形
                end else begin
                    case (item)
                        3'd0: begin                  // 进入图片子菜单
                            page <= 2'd2;
                            item <= 3'd0;
                        end
                        3'd1: v_bright   <= (v_bright >= 4'd10) ? 4'd0 : v_bright + 4'd1;
                        3'd2: v_contrast <= (v_contrast >= 4'd10) ? 4'd0 : v_contrast + 4'd1;
                        3'd3: v_scale    <= (v_scale == 2'd2) ? 2'd0 : v_scale + 2'd1;
                        3'd4: v_vol      <= (v_vol >= 4'd10) ? 4'd0 : v_vol + 4'd1;
                        3'd5: begin                              // 进 VU 子菜单
                            page <= 2'd3;
                            item <= 3'd0;
                        end
                        default: v_sub   <= ~v_sub;               // 字幕开关
                    endcase
                end
            end

            // ---- KEY1/KEY2：菜单里移动光标 ----
            if (open) begin
                if (key_up)
                    item <= (item == 3'd0) ? row_max : item - 3'd1;
                if (key_down)
                    item <= (item == row_max) ? 3'd0 : item + 3'd1;
            end
        end
    end

    // 参数输出（下游在 cfg_commit 时锁存，避免帧内跳变）
    always @(posedge clk) begin
        cfg_trans    <= v_trans;
        cfg_bright   <= v_bright;
        cfg_contrast <= v_contrast;
        cfg_scale    <= v_scale;
        cfg_mus      <= v_mus;
        cfg_auto     <= v_auto;
        cfg_vol      <= v_vol;
        cfg_meter    <= v_meter;
        cfg_sub      <= v_sub;
        cfg_hold     <= v_hold;
        cfg_style    <= v_style;
    end

    reg [11:0] y_d;
    always @(posedge clk) y_d <= y;
    always @(posedge clk) cfg_commit <= (y == 12'd0) && (y_d != 12'd0);

    // ------------------------------------------------------------------
    // 几何区域
    // ------------------------------------------------------------------
    wire frame_start = (x == 12'd0) && (y == 12'd0);

    // ------------------------------------------------------------------
    // 渲染快照：面板尺寸/行号/高亮都跟着页走，如果按键正好落在帧中间，
    // 同一帧上半张用一个 r_page、下半张用另一个 r_page，会撕成两半面板。
    // 这里把"要显示的状态"在帧首统一打一拍，整帧用同一份。
    // ------------------------------------------------------------------
    reg        r_open;
    reg [1:0]  r_page;
    reg [2:0]  r_item;

    // 淡入淡出：mfade 0=全透明 8=不透明，每帧走 1 级（30fps 下 8 帧 ≈ 0.27s）
    //   r_open 立刻跟随 open（它只决定"要不要画"），mfade 慢慢跟；
    //   换页（二级菜单）时先淡出到 0 再换 r_page，看起来就是"暗下去再亮起来"。
    reg [3:0] mfade;
    wire      page_chg = (r_page != page);
    always @(posedge clk or posedge rst) begin
        if (rst) mfade <= 4'd0;
        else if (frame_start) begin
            if (!open || page_chg) mfade <= (mfade == 4'd0) ? 4'd0 : mfade - 4'd1;
            else                   mfade <= (mfade == 4'd8) ? 4'd8 : mfade + 4'd1;
        end
    end
    wire mvis = r_open | (mfade != 4'd0);      // 渲染用：淡出期间继续画

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            r_open <= 1'b0;
            r_page <= 2'd0;
            r_item <= 3'd0;
        end else if (frame_start) begin
            r_open <= open;
            // 页面：只在全透明时更新 —— 换页要先淡出，换完再淡入。
            // 光标：稳态(mfade==8)也要更新，否则菜单一打开高亮条就再也不动
            //       （上一版只判 mfade==0，正好把稳态漏掉了）。
            //       换页待处理时冻结，让淡出过程中的还是旧页的旧高亮。
            if (mfade == 4'd0) begin
                r_page <= page;
                r_item <= item;
            end else if ((mfade == 4'd8) && !page_chg) begin
                r_item <= item;
            end
        end
    end

    // 面板高度按页变化（都垂直居中）：
    //   设置页 7 行      -> 596
    //   音乐列表最多 8 行 -> 660
    //   图片子菜单 2 行   -> 260（不留大片空白）
    wire [11:0] py0_cur = (r_page == 2'd2) ? 12'd192 :   // IMG：3 行
                          (r_page == 2'd3) ? 12'd230 :   // VU ：2 行
                          (r_page == 2'd1) ? 12'd30  : 12'd62;
    wire [11:0] ph_cur  = (r_page == 2'd2) ? 12'd336 :
                          (r_page == 2'd3) ? 12'd260 :
                          (r_page == 2'd1) ? 12'd660 : 12'd596;

    wire in_panel  = (x >= PX0) && (x < PX0 + PW) && (y >= py0_cur) && (y < py0_cur + ph_cur);
    wire [11:0] rx = x - PX0;
    wire [11:0] ry = y - py0_cur;

    wire in_border = in_panel &&
                     ((rx < 12'd2) || (rx >= PW - 2) || (ry < 12'd2) || (ry >= ph_cur - 2));

    // 行区：音乐页 8 行、设置页 7 行、二级页 2 行（别压到底部提示行）
    wire [11:0] row_end = (r_page == 2'd2) ? 12'd272 :
                          (r_page == 2'd3) ? 12'd208 :
                          (r_page == 2'd1) ? 12'd592 : 12'd528;
    wire row_band  = in_panel && (ry >= 12'd80) && (ry < row_end);
    wire [2:0] ridx = (ry - 12'd80) >> 6;
    wire [11:0] wy  = ry - 12'd80 - {ridx, 6'b000000};
    wire row_tv     = (wy >= 12'd12) && (wy < 12'd44);
    wire [3:0] row_fr = (wy - 12'd12) >> 1;

    // 每一行自己的取值
    wire [3:0] row_val = (r_page == 2'd1) ? {1'b0, v_mus} :
                         (r_page == 2'd2) ? ((ridx == 3'd0) ? {3'b000, v_auto}  :
                                             (ridx == 3'd1) ? {2'b00, v_trans} :
                                                              {1'b0, v_hold})  :
                         (r_page == 2'd3) ? ((ridx == 3'd0) ? {3'b000, v_meter}
                                                            : {3'b000, v_style}) :
                         (ridx == 3'd1) ? v_bright            :
                         (ridx == 3'd2) ? v_contrast          :
                         (ridx == 3'd3) ? {2'b00, v_scale}    :
                         (ridx == 3'd4) ? v_vol               :
                         (ridx == 3'd5) ? {3'b000, v_meter}   :
                         (ridx == 3'd6) ? {3'b000, v_sub}     : 4'd0;

    wire title_hv = (x >= PX0 + 32) && (x < PX0 + 160) && (y >= py0_cur + 24) && (y < py0_cur + 56);
    wire [11:0] tcx = x - (PX0 + 32);

    wire label_hv = (x >= PX0 + 32) && (x < PX0 + 160) && row_band && row_tv;
    wire [11:0] lcx = x - (PX0 + 32);

    wire value_hv = (x >= PX0 + 300) && (x < PX0 + 524) && row_band && row_tv;
    wire [11:0] vcx = x - (PX0 + 300);

    wire hint_hv  = (x >= PX0 + 32) && (x < PX0 + 320) &&
                    (y >= py0_cur + ph_cur - 28) && (y < py0_cur + ph_cur - 12);
    wire [11:0] hcx = x - (PX0 + 32);

    // ---- 底部滚动字幕条 ----
    reg [11:0] scroll;

    // 字幕按 64 字（2048px）循环：和字模索引 sub_tx[10:5] 的取模周期一致，
    // 回卷时画面完全连续，不会跳字。
    localparam [11:0] SUB_LEN = 12'd2048;

    always @(posedge clk or posedge rst) begin
        if (rst)
            scroll <= 12'd0;
        else if (frame_start) begin
            if (scroll >= SUB_LEN)
                scroll <= 12'd0;
            else
                scroll <= scroll + 12'd3;
        end
    end

    // 字幕条固定在 y 592..640（音频条 468..579 下方，留 13 行空隙），
    // 整条与频谱完全分离：两个开关任意组合都不会互相遮挡。
    wire        sub_bar = (y >= 12'd592) && (y < 12'd640);
    wire [13:0] sub_x   = {2'b00, x} + {2'b00, scroll};
    wire [13:0] sub_tx  = sub_x - 14'd24;
    wire        sub_tv  = (y >= 12'd600) && (y < 12'd632);     // 32 行字高
    wire        sub_hv  = sub_tv;      // 索引按 64 字取模，越界自然落在空格上

    // 没有可用图片时在底部条上显示 "NO IMAGE"（居中，8 字 x 32px）
    wire        alert_hv = (y >= 12'd600) && (y < 12'd632) &&
                           (x >= 12'd512) && (x < 12'd768);

    function [5:0] g_msg;
        input [2:0] i;
        begin
            case (i)
                3'd0: g_msg = 6'd13;   // N
                3'd1: g_msg = 6'd14;   // O
                3'd2: g_msg = 6'd37;   //
                3'd3: g_msg = 6'd8;    // I
                3'd4: g_msg = 6'd12;   // M
                3'd5: g_msg = 6'd0;    // A
                3'd6: g_msg = 6'd6;    // G
                default: g_msg = 6'd4; // E
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 字模索引
    // ------------------------------------------------------------------
    function [5:0] g_title;
        input [1:0] pg;                  // 0=设置 1=音乐 2=图片子菜单
        input [1:0] i;
        begin
            case (pg)
                2'd1: case (i)               // MUS
                    2'd0: g_title = 6'd12;   // M
                    2'd1: g_title = 6'd20;   // U
                    2'd2: g_title = 6'd18;   // S
                    default: g_title = 6'd37;
                endcase
                2'd2: case (i)               // IMG
                    2'd0: g_title = 6'd8;    // I
                    2'd1: g_title = 6'd12;   // M
                    2'd2: g_title = 6'd6;    // G
                    default: g_title = 6'd37;
                endcase
                2'd3: case (i)               // VU
                    2'd0: g_title = 6'd21;   // V
                    2'd1: g_title = 6'd20;   // U
                    default: g_title = 6'd37;
                endcase
                default: case (i)            // 调试菜单
                    2'd0: g_title = 6'd42;   // 调
                    2'd1: g_title = 6'd43;   // 试
                    2'd2: g_title = 6'd44;   // 菜
                    default: g_title = 6'd45; // 单
                endcase
            endcase
        end
    endfunction

    function [7:0] asc2g;                 // ASCII -> 字模编号
        input [7:0] c;
        begin
            if ((c >= "A") && (c <= "Z"))      asc2g = 8'd0  + (c - "A");
            else if ((c >= "a") && (c <= "z")) asc2g = 8'd0  + (c - "a");
            else if ((c >= "0") && (c <= "9")) asc2g = 8'd26 + (c - "0");
            else                               asc2g = 8'd37;
        end
    endfunction

    function [5:0] g_label;
        input [1:0] pg;                  // 0=设置 1=音乐列表 2=图片子菜单
        input [2:0] it;
        input [1:0] i;
        input [2:0] total;
        begin
            g_label = 6'd37;             // 空格
            if (pg == 2'd1) begin
                // ---- 音乐列表：OFF / GEN / T1..TN ----
                case (it)
                    3'd0: case (i)
                        2'd0: g_label = 6'd14;   // O
                        2'd1: g_label = 6'd5;    // F
                        2'd2: g_label = 6'd5;    // F
                        default: g_label = 6'd37;
                    endcase
                    3'd1: case (i)
                        2'd0: g_label = 6'd6;    // G
                        2'd1: g_label = 6'd4;    // E
                        2'd2: g_label = 6'd13;   // N
                        default: g_label = 6'd37;
                    endcase
                    default: begin
                        // 只有真实存在的曲目才显示 Tn；空行整个留白
                        // （字形 27='1' 28='2'…；行号 it=2 对应 T1，基址 25）
                        if ((it >= 3'd2) && (it < (total + 3'd2))) begin
                            case (i)
                                2'd0: g_label = 6'd19;        // T
                                2'd1: g_label = 6'd25 + it;   // 数字
                                default: g_label = 6'd37;
                            endcase
                        end
                    end
                endcase
            end else if (pg == 2'd2) begin
                // ---- 图片子菜单：AUT / 切屏效果 ----
                if (it == 3'd0) begin
                    case (i)
                        2'd0: g_label = 6'd0;    // A
                        2'd1: g_label = 6'd20;   // U
                        2'd2: g_label = 6'd19;   // T
                        default: g_label = 6'd37;
                    endcase
                end else if (it == 3'd1) begin
                    case (i)
                        2'd0: g_label = 6'd46;   // 切
                        2'd1: g_label = 6'd47;   // 屏
                        2'd2: g_label = 6'd48;   // 效
                        default: g_label = 6'd49; // 果
                    endcase
                end else if (it == 3'd2) begin
                    case (i)                     // INT（切屏间隔）
                        2'd0: g_label = 6'd8;    // I
                        2'd1: g_label = 6'd13;   // N
                        2'd2: g_label = 6'd19;   // T
                        default: g_label = 6'd37;
                    endcase
                end
            end else if (pg == 2'd3) begin
                // ---- 音频可视化子菜单：VU / MODE ----
                if (it == 3'd0) begin
                    case (i)
                        2'd0: g_label = 6'd21;   // V
                        2'd1: g_label = 6'd20;   // U
                        default: g_label = 6'd37;
                    endcase
                end else if (it == 3'd1) begin
                    case (i)                     // MODE
                        2'd0: g_label = 6'd12;   // M
                        2'd1: g_label = 6'd14;   // O
                        2'd2: g_label = 6'd3;    // D
                        default: g_label = 6'd4; // E
                    endcase
                end
            end else begin
                // ---- 设置页 ----
                case (it)
                    3'd0: case (i)               // IMG（进子菜单）
                        2'd0: g_label = 6'd8;    // I
                        2'd1: g_label = 6'd12;   // M
                        2'd2: g_label = 6'd6;    // G
                        default: g_label = 6'd37;
                    endcase
                    3'd1: case (i)
                        2'd0: g_label = 6'd50;   // 亮
                        2'd1: g_label = 6'd51;   // 度
                        default: g_label = 6'd37;
                    endcase
                    3'd2: case (i)
                        2'd0: g_label = 6'd52;   // 对
                        2'd1: g_label = 6'd53;   // 比
                        2'd2: g_label = 6'd51;   // 度
                        default: g_label = 6'd37;
                    endcase
                    3'd3: case (i)
                        2'd0: g_label = 6'd54;   // 缩
                        2'd1: g_label = 6'd55;   // 放
                        2'd2: g_label = 6'd56;   // 模
                        default: g_label = 6'd57; // 式
                    endcase
                    3'd4: case (i)
                        2'd0: g_label = 6'd60;   // 音
                        2'd1: g_label = 6'd61;   // 量
                        default: g_label = 6'd37;
                    endcase
                    3'd5: case (i)               // VU（电平表开关）
                        2'd0: g_label = 6'd21;   // V
                        2'd1: g_label = 6'd20;   // U
                        default: g_label = 6'd37;
                    endcase
                    3'd6: case (i)               // SUB（字幕开关）
                        2'd0: g_label = 6'd18;   // S
                        2'd1: g_label = 6'd20;   // U
                        2'd2: g_label = 6'd1;    // B
                        default: g_label = 6'd37;
                    endcase
                    default: g_label = 6'd37;
                endcase
            end
        end
    endfunction

    // 底部提示行（所有页统一）："OK SET   K4 EXIT"
    //   KEY3 = 确认/改值/进入，KEY4 = 关闭；上下移动由高亮行自己说明。
    function [5:0] g_hint;
        input [4:0] i;
        begin
            case (i)
                5'd0:  g_hint = 6'd14;   // O
                5'd1:  g_hint = 6'd10;   // K
                5'd2:  g_hint = 6'd37;
                5'd3:  g_hint = 6'd18;   // S
                5'd4:  g_hint = 6'd4;    // E
                5'd5:  g_hint = 6'd19;   // T
                5'd6:  g_hint = 6'd37;
                5'd7:  g_hint = 6'd37;
                5'd8:  g_hint = 6'd10;   // K
                5'd9:  g_hint = 6'd30;   // 4
                5'd10: g_hint = 6'd37;
                5'd11: g_hint = 6'd4;    // E
                5'd12: g_hint = 6'd23;   // X
                5'd13: g_hint = 6'd8;    // I
                5'd14: g_hint = 6'd19;   // T
                default: g_hint = 6'd37;
            endcase
        end
    endfunction

    // 字幕文案： "NOW PLAYING <8字节歌名>  MUSIC FRAME"（共 40 字，循环滚动）
    //   12..19 显示 FAT 目录里的 8.3 名字；0x00 当空格
    // 字幕文案：
    //   play=0（音乐 OFF）："MUSIC PHOTO FRAME"（17 字）
    //   play=1           ："NOW PLAYING <8字节歌名>  MUSIC FRAME"（33 字）
    //   0x00 当空格
    // 字幕文案（按 64 字周期滚动，索引 0..63）：
    //   play=0（音乐 OFF）："MUSIC PHOTO FRAME"（17 字）
    //   play=1           ："NOW PLAYING <8字节歌名> MUSIC FRAME"（正好 32 字）
    //   0x00 当空格
    function [5:0] g_sub;
        input [5:0]  i;
        input [63:0] nm;
        input        play;
        begin
            if (!play) begin
                case (i)
                    6'd0:  g_sub = 6'd12;  // M
                    6'd1:  g_sub = 6'd20;  // U
                    6'd2:  g_sub = 6'd18;  // S
                    6'd3:  g_sub = 6'd8;   // I
                    6'd4:  g_sub = 6'd2;   // C
                    6'd5:  g_sub = 6'd37;
                    6'd6:  g_sub = 6'd15;  // P
                    6'd7:  g_sub = 6'd7;   // H
                    6'd8:  g_sub = 6'd14;  // O
                    6'd9:  g_sub = 6'd19;  // T
                    6'd10: g_sub = 6'd14;  // O
                    6'd11: g_sub = 6'd37;
                    6'd12: g_sub = 6'd5;   // F
                    6'd13: g_sub = 6'd17;  // R
                    6'd14: g_sub = 6'd0;   // A
                    6'd15: g_sub = 6'd12;  // M
                    6'd16: g_sub = 6'd4;   // E
                    default: g_sub = 6'd37;
                endcase
            end else begin
                case (i)
                    6'd0:  g_sub = 6'd13;  // N
                    6'd1:  g_sub = 6'd14;  // O
                    6'd2:  g_sub = 6'd22;  // W
                    6'd3:  g_sub = 6'd37;  //
                    6'd4:  g_sub = 6'd15;  // P
                    6'd5:  g_sub = 6'd11;  // L
                    6'd6:  g_sub = 6'd0;   // A
                    6'd7:  g_sub = 6'd24;  // Y
                    6'd8:  g_sub = 6'd8;   // I
                    6'd9:  g_sub = 6'd13;  // N
                    6'd10: g_sub = 6'd6;   // G
                    6'd11: g_sub = 6'd37;  //
                    6'd12: g_sub = asc2g(nm[7:0]);
                    6'd13: g_sub = asc2g(nm[15:8]);
                    6'd14: g_sub = asc2g(nm[23:16]);
                    6'd15: g_sub = asc2g(nm[31:24]);
                    6'd16: g_sub = asc2g(nm[39:32]);
                    6'd17: g_sub = asc2g(nm[47:40]);
                    6'd18: g_sub = asc2g(nm[55:48]);
                    6'd19: g_sub = asc2g(nm[63:56]);
                    6'd20: g_sub = 6'd37;
                    6'd21: g_sub = 6'd12;  // M
                    6'd22: g_sub = 6'd20;  // U
                    6'd23: g_sub = 6'd18;  // S
                    6'd24: g_sub = 6'd8;   // I
                    6'd25: g_sub = 6'd2;   // C
                    6'd26: g_sub = 6'd37;
                    6'd27: g_sub = 6'd5;   // F
                    6'd28: g_sub = 6'd17;  // R
                    6'd29: g_sub = 6'd0;   // A
                    6'd30: g_sub = 6'd12;  // M
                    6'd31: g_sub = 6'd4;   // E
                    default: g_sub = 6'd37;
                endcase
            end
        end
    endfunction

    function [5:0] g_val;
        input [1:0] pg;
        input [2:0] it;
        input [2:0] i;
        input [3:0] v;
        input [2:0] total;
        begin
            g_val = 6'd37;
            if (pg == 2'd1) begin
                // 音乐列表：当前播放的那一行标一个 '>'
                case (i)
                    3'd0: g_val = (it == v[2:0]) ? 6'd40 : 6'd37;
                    default: g_val = 6'd37;
                endcase
            end else if (pg == 2'd2) begin
                if (it == 3'd0) begin            // AUT：ON / OFF
                    case (i)
                        3'd0: g_val = 6'd14;                       // O
                        3'd1: g_val = v[0] ? 6'd13 : 6'd5;         // N / F
                        3'd2: g_val = v[0] ? 6'd37 : 6'd5;         // - / F
                        default: g_val = 6'd37;
                    endcase
                end else if (it == 3'd1) begin   // 切屏效果
                    case (i)
                        3'd0: g_val = (v == 4'd0) ? 6'd5 : (v == 4'd1) ? 6'd18 : (v == 4'd2) ? 6'd22 : 6'd2;
                        3'd1: g_val = (v == 4'd0) ? 6'd0 : (v == 4'd1) ? 6'd11 : (v == 4'd2) ? 6'd8  : 6'd20;
                        3'd2: g_val = (v == 4'd0) ? 6'd3 : (v == 4'd1) ? 6'd8  : (v == 4'd2) ? 6'd15 : 6'd19;
                        3'd3: g_val = (v == 4'd0) ? 6'd4 : (v == 4'd1) ? 6'd3  : (v == 4'd2) ? 6'd4  : 6'd37;
                        3'd4: g_val = (v == 4'd1) ? 6'd4 : 6'd37;
                        default: g_val = 6'd37;
                    endcase
                end else begin                   // INT：3S/5S/8S/15S/30S
                    case (v[2:0])
                        3'd0: begin                  // 3S
                            case (i) 3'd0: g_val = 6'd29; default: g_val = (i == 3'd1) ? 6'd18 : 6'd37; endcase
                        end
                        3'd1: begin                  // 5S
                            case (i) 3'd0: g_val = 6'd31; default: g_val = (i == 3'd1) ? 6'd18 : 6'd37; endcase
                        end
                        3'd2: begin                  // 8S
                            case (i) 3'd0: g_val = 6'd34; default: g_val = (i == 3'd1) ? 6'd18 : 6'd37; endcase
                        end
                        3'd3: begin                  // 15S
                            case (i)
                                3'd0: g_val = 6'd27;   // 1
                                3'd1: g_val = 6'd31;   // 5
                                default: g_val = (i == 3'd2) ? 6'd18 : 6'd37;
                            endcase
                        end
                        default: begin               // 30S
                            case (i)
                                3'd0: g_val = 6'd29;   // 3
                                3'd1: g_val = 6'd26;   // 0
                                default: g_val = (i == 3'd2) ? 6'd18 : 6'd37;
                            endcase
                        end
                    endcase
                end
            end else if (pg == 2'd3) begin
                if (it == 3'd0) begin            // VU：ON / OFF
                    case (i)
                        3'd0: g_val = 6'd14;
                        3'd1: g_val = v[0] ? 6'd13 : 6'd5;
                        3'd2: g_val = v[0] ? 6'd37 : 6'd5;
                        default: g_val = 6'd37;
                    endcase
                end else begin                    // MODE：BAR / CIRC
                    if (v[0] == 1'b0) begin
                        case (i)                     // BAR
                            3'd0: g_val = 6'd1;      // B
                            3'd1: g_val = 6'd0;      // A
                            3'd2: g_val = 6'd17;     // R
                            default: g_val = 6'd37;
                        endcase
                    end else begin
                        case (i)                     // CIRC
                            3'd0: g_val = 6'd2;      // C
                            3'd1: g_val = 6'd8;      // I
                            3'd2: g_val = 6'd17;     // R
                            default: g_val = (i == 3'd3) ? 6'd2 : 6'd37;
                        endcase
                    end
                end
            end else
            case (it)
                3'd0: g_val = (i == 3'd0) ? 6'd40 : 6'd37;   // '>'：表示可进入
                3'd3: begin                       // FIT / FILL / STRETCH
                    case (i)
                        3'd0: g_val = (v == 4'd0) ? 6'd5  : (v == 4'd1) ? 6'd5  : 6'd18;
                        3'd1: g_val = (v == 4'd0) ? 6'd8  : (v == 4'd1) ? 6'd8  : 6'd19;
                        3'd2: g_val = (v == 4'd0) ? 6'd19 : (v == 4'd1) ? 6'd11 : 6'd17;
                        3'd3: g_val = (v == 4'd0) ? 6'd37 : (v == 4'd1) ? 6'd11 : 6'd4;
                        3'd4: g_val = (v == 4'd0) ? 6'd37 : (v == 4'd1) ? 6'd11 : 6'd19;
                        3'd5: g_val = (v == 4'd2) ? 6'd2 : 6'd37;
                        default: g_val = (v == 4'd2) ? 6'd7 : 6'd37;
                    endcase
                end
                3'd5, 3'd6: begin                 // VU / SUB：ON / OFF
                    case (i)
                        3'd0: g_val = 6'd14;                       // O
                        3'd1: g_val = v[0] ? 6'd13 : 6'd5;         // N / F
                        3'd2: g_val = v[0] ? 6'd37 : 6'd5;         // - / F
                        default: g_val = 6'd37;
                    endcase
                end
                3'd1, 3'd2, 3'd4: begin           // 亮度 / 对比度 / 音量：百分比
                    if (v == 4'd10) begin
                        case (i)
                            3'd0: g_val = 6'd27;   // 1
                            3'd1: g_val = 6'd26;   // 0
                            3'd2: g_val = 6'd26;   // 0
                            3'd3: g_val = 6'd36;   // %
                            default: g_val = 6'd37;
                        endcase
                    end else if (v == 4'd0) begin
                        case (i)
                            3'd0: g_val = 6'd26;   // 0
                            3'd1: g_val = 6'd36;   // %
                            default: g_val = 6'd37;
                        endcase
                    end else begin
                        case (i)
                            3'd0: g_val = 6'd26 + v;  // 十位
                            3'd1: g_val = 6'd26;      // 0
                            3'd2: g_val = 6'd36;      // %
                            default: g_val = 6'd37;
                        endcase
                    end
                end
                default: g_val = 6'd37;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 第一级：区域底色 + 文本请求
    // ------------------------------------------------------------------
    reg        s0_text;
    reg        s0_tmenu;
    reg [5:0]  s0_glyph;
    reg [3:0]  s0_frow;
    reg [3:0]  s0_fcol;
    reg [23:0] s0_tcolor;
    reg [23:0] s0_base_rgb;
    reg [3:0]  s0_base_alpha;

    always @(*) begin
        // 默认：透明
        s0_text       = 1'b0;
        s0_glyph      = 6'd37;
        s0_frow       = 4'd0;
        s0_fcol       = 4'd0;
        s0_tcolor     = C_LABEL;
        s0_base_rgb   = 24'h00_00_00;
        s0_base_alpha = 4'd0;

        // ---- 无图片告警条 ----
        if (alert && sub_bar) begin
            s0_base_rgb   = 24'h30_00_00;
            s0_base_alpha = 4'd7;
        end

        // ---- 字幕条底色（菜单关着才显示）----
        if (!mvis && v_sub && sub_bar) begin
            s0_base_rgb   = 24'h00_00_00;
            s0_base_alpha = 4'd4;                  // 25% 黑，文字清晰又不挡图
        end

        // ---- 菜单底色 ----
        if (mvis) begin
            if (!in_panel) begin
                s0_base_rgb   = C_MASK;
                s0_base_alpha = 4'd3;              // 全屏 37.5% 黑遮罩
            end else if (in_border) begin
                s0_base_rgb   = C_BORDER;
                s0_base_alpha = 4'd8;
            end else if (row_band && (ridx == r_item)) begin
                s0_base_rgb   = C_HLBG;
                s0_base_alpha = 4'd8;
            end else begin
                s0_base_rgb   = C_PANEL;
                s0_base_alpha = 4'd8;
            end
            // 淡入淡出：整层（遮罩/边框/面板/高亮）按 mfade(0..8) 缩放透明度
            //   ★ 必须显式补到 8 位：Verilog 乘法结果宽度 = max(操作数宽度)，
            //     4 位 x 4 位 会先截成 4 位（8*8=64 -> 0），再右移就只剩 0/1。
            s0_base_alpha = ({4'd0, s0_base_alpha} * {4'd0, mfade}) >> 3;
        end

        // ---- 文本：菜单优先，其次字幕 ----
        s0_tmenu = 1'b0;                       // 0 = 字幕/告警（不参与淡入淡出）
        if (mvis && title_hv) begin
            s0_text   = 1'b1;
            s0_tmenu  = 1'b1;
            s0_glyph  = g_title(r_page, tcx[6:5]);
            s0_fcol   = tcx[4:1];
            s0_frow   = (y - (py0_cur + 24)) >> 1;
            s0_tcolor = C_TITLE;
        end else if (mvis && label_hv) begin
            s0_text   = 1'b1;
            s0_tmenu  = 1'b1;
            s0_glyph  = g_label(r_page, ridx, lcx[6:5], mus_total[2:0]);
            s0_fcol   = lcx[4:1];
            s0_frow   = row_fr;
            s0_tcolor = C_LABEL;
        end else if (mvis && value_hv) begin
            s0_text   = 1'b1;
            s0_tmenu  = 1'b1;
            s0_glyph  = g_val(r_page, ridx, vcx[7:5], row_val, mus_total[2:0]);
            s0_fcol   = vcx[4:1];
            s0_frow   = row_fr;
            s0_tcolor = C_VALUE;
        end else if (mvis && hint_hv) begin
            s0_text   = 1'b1;
            s0_tmenu  = 1'b1;
            s0_glyph  = g_hint(hcx[8:4]);
            s0_fcol   = hcx[3:0];
            s0_frow   = y - (py0_cur + ph_cur - 28);
            s0_tcolor = C_HINT;
        end else if (alert && alert_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_msg(x[8:5] - 5'd16);
            s0_fcol   = x[4:1];
            s0_frow   = (y - 12'd600) >> 1;
            s0_tcolor = 24'hFF_60_60;
        end else if (!mvis && v_sub && sub_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_sub(sub_tx[10:5], mus_name, (v_mus != 3'd0));
            s0_fcol   = sub_tx[4:1];
            s0_frow   = (y - 12'd600) >> 1;
            s0_tcolor = C_TITLE;
        end
    end

    // ------------------------------------------------------------------
    // 第二级：字模 ROM
    // ------------------------------------------------------------------
    reg        s1_text;
    reg        s1_tmenu;
    reg [3:0]  s1_fcol;
    reg [23:0] s1_tcolor;
    reg [23:0] s1_base_rgb;
    reg [3:0]  s1_base_alpha;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_text       <= 1'b0;
            s1_tmenu      <= 1'b0;
            s1_fcol       <= 4'd0;
            s1_tcolor     <= 24'd0;
            s1_base_rgb   <= 24'd0;
            s1_base_alpha <= 4'd0;
        end else begin
            s1_text       <= s0_text;
            s1_tmenu      <= s0_tmenu;
            s1_fcol       <= s0_fcol;
            s1_tcolor     <= s0_tcolor;
            s1_base_rgb   <= s0_base_rgb;
            s1_base_alpha <= s0_base_alpha;
        end
    end

    // 字模索引先打一拍再送 ROM：把"区域比较 + 取字函数"从 BRAM 地址端拆开
    reg [5:0] s0a_glyph;
    reg [3:0] s0a_frow;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s0a_glyph <= 6'd37;
            s0a_frow  <= 4'd0;
        end else begin
            s0a_glyph <= s0_glyph;
            s0a_frow  <= s0_frow;
        end
    end

    wire [9:0]  rom_addr = {s0a_glyph, s0a_frow};
    wire [15:0] rom_dout;

    font_rom u_font_rom (
        .clk  (clk),
        .addr (rom_addr),
        .dout (rom_dout)
    );

    // 标志位再补一拍，与 BRAM 输出同拍
    reg        s2_text;
    reg        s2_tmenu;
    reg [3:0]  s2_fcol;
    reg [23:0] s2_tcolor;
    reg [23:0] s2_base_rgb;
    reg [3:0]  s2_base_alpha;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2_text       <= 1'b0;
            s2_tmenu      <= 1'b0;
            s2_fcol       <= 4'd0;
            s2_tcolor     <= 24'd0;
            s2_base_rgb   <= 24'd0;
            s2_base_alpha <= 4'd0;
        end else begin
            s2_text       <= s1_text;
            s2_tmenu      <= s1_tmenu;
            s2_fcol       <= s1_fcol;
            s2_tcolor     <= s1_tcolor;
            s2_base_rgb   <= s1_base_rgb;
            s2_base_alpha <= s1_base_alpha;
        end
    end

    wire rom_bit = rom_dout[15 - s2_fcol];

    // ------------------------------------------------------------------
    // 第三级：合成输出（比 x/y 晚 2 拍）
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            osd_on    <= 1'b0;
            osd_rgb   <= 24'd0;
            osd_alpha <= 4'd0;
        end else if (s2_text && rom_bit) begin
            // 菜单文字跟着 mfade 淡；字幕/告警恒为 8（不参与淡入淡出）
            osd_on    <= s2_tmenu ? (mfade != 4'd0) : 1'b1;
            osd_rgb   <= s2_tcolor;
            osd_alpha <= s2_tmenu ? mfade : 4'd8;
        end else begin
            osd_on    <= (s2_base_alpha != 4'd0);
            osd_rgb   <= s2_base_rgb;
            osd_alpha <= s2_base_alpha;
        end
    end

endmodule
