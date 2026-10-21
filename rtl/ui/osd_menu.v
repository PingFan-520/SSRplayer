// ============================================================================
//  osd_menu.v —— 调试菜单：全屏半透明遮罩 + 居中面板 + 6 项参数
//
//  纯像素域、纯坐标实时生成：不读帧缓存、不占 SDRAM 带宽。
//  四级流水（区域 -> 地址 -> 字模 -> 合成），输出比输入 x/y 晚 3 个像素。
//
//  按键：key_menu 开合，key_up/key_down 选择，key_ok 改值
// ============================================================================
`timescale 1ns / 1ps

module osd_menu #(
    parameter integer HACTIVE = 1280,
    parameter integer VACTIVE = 720,
    parameter integer PX0 = 360,      // 面板左上角
    parameter integer PY0 = 110,
    parameter integer PW  = 560,
    parameter integer PH  = 500
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
    output reg         cfg_sub,
    output reg  [3:0]  cfg_vol
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
    reg [2:0]  item;
    reg [1:0]  v_trans;
    reg [3:0]  v_bright;
    reg [3:0]  v_contrast;
    reg [1:0]  v_scale;
    reg        v_sub;
    reg [3:0]  v_vol;

    // 当前光标项的取值
    wire [3:0] cur_val = (item == 3'd0) ? {2'b00, v_trans}   :
                         (item == 3'd1) ? v_bright            :
                         (item == 3'd2) ? v_contrast          :
                         (item == 3'd3) ? {2'b00, v_scale}    :
                         (item == 3'd4) ? {3'b000, v_sub}     : v_vol;

    assign menu_open = open;
    assign dbg_item  = item;
    assign dbg_val   = cur_val;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            open       <= 1'b0;
            item       <= 3'd0;
            v_trans    <= 2'd0;
            v_bright   <= 4'd10;
            v_contrast <= 4'd10;
            v_scale    <= 2'd0;
            v_sub      <= 1'b1;
            v_vol      <= 4'd6;
        end else begin
            if (key_menu)
                open <= ~open;

            if (open) begin
                if (key_up)
                    item <= (item == 3'd0) ? 3'd5 : item - 3'd1;
                if (key_down)
                    item <= (item == 3'd5) ? 3'd0 : item + 3'd1;

                if (key_ok) begin
                    case (item)
                        3'd0: v_trans    <= (v_trans == 2'd3) ? 2'd0 : v_trans + 2'd1;
                        3'd1: v_bright   <= (v_bright >= 4'd10) ? 4'd0 : v_bright + 4'd1;
                        3'd2: v_contrast <= (v_contrast >= 4'd10) ? 4'd0 : v_contrast + 4'd1;
                        3'd3: v_scale    <= (v_scale == 2'd2) ? 2'd0 : v_scale + 2'd1;
                        3'd4: v_sub      <= ~v_sub;
                        default: v_vol   <= (v_vol >= 4'd10) ? 4'd0 : v_vol + 4'd1;
                    endcase
                end
            end
        end
    end

    // 参数输出（下游在 cfg_commit 时锁存，避免帧内跳变）
    always @(posedge clk) begin
        cfg_trans    <= v_trans;
        cfg_bright   <= v_bright;
        cfg_contrast <= v_contrast;
        cfg_scale    <= v_scale;
        cfg_sub      <= v_sub;
        cfg_vol      <= v_vol;
    end

    reg [11:0] y_d;
    always @(posedge clk) y_d <= y;
    always @(posedge clk) cfg_commit <= (y == 12'd0) && (y_d != 12'd0);

    // 字幕开关也在帧首提交，避免一行字被切成两半
    reg sub_on;
    always @(posedge clk or posedge rst) begin
        if (rst)            sub_on <= 1'b1;
        else if (cfg_commit) sub_on <= v_sub;
    end

    // ------------------------------------------------------------------
    // 几何区域
    // ------------------------------------------------------------------
    wire in_panel  = (x >= PX0) && (x < PX0 + PW) && (y >= PY0) && (y < PY0 + PH);
    wire [11:0] rx = x - PX0;
    wire [11:0] ry = y - PY0;

    wire in_border = in_panel &&
                     ((rx < 12'd2) || (rx >= PW - 2) || (ry < 12'd2) || (ry >= PH - 2));

    wire row_band  = in_panel && (ry >= 12'd80) && (ry < 12'd464);
    wire [2:0] ridx = (ry - 12'd80) >> 6;
    wire [11:0] wy  = ry - 12'd80 - {ridx, 6'b000000};
    wire row_tv     = (wy >= 12'd12) && (wy < 12'd44);
    wire [3:0] row_fr = (wy - 12'd12) >> 1;

    // 每一行自己的取值
    wire [3:0] row_val = (ridx == 3'd0) ? {2'b00, v_trans}   :
                         (ridx == 3'd1) ? v_bright            :
                         (ridx == 3'd2) ? v_contrast          :
                         (ridx == 3'd3) ? {2'b00, v_scale}    :
                         (ridx == 3'd4) ? {3'b000, v_sub}     : v_vol;

    wire title_hv = (x >= PX0 + 32) && (x < PX0 + 160) && (y >= PY0 + 24) && (y < PY0 + 56);
    wire [11:0] tcx = x - (PX0 + 32);

    wire label_hv = (x >= PX0 + 32) && (x < PX0 + 160) && row_band && row_tv;
    wire [11:0] lcx = x - (PX0 + 32);

    wire value_hv = (x >= PX0 + 300) && (x < PX0 + 524) && row_band && row_tv;
    wire [11:0] vcx = x - (PX0 + 300);

    wire hint_hv  = (x >= PX0 + 32) && (x < PX0 + 320) &&
                    (y >= PY0 + PH - 40) && (y < PY0 + PH - 24);
    wire [11:0] hcx = x - (PX0 + 32);

    // ---- 底部滚动字幕条 ----
    reg [11:0] scroll;
    wire frame_start = (x == 12'd0) && (y == 12'd0);

    always @(posedge clk or posedge rst) begin
        if (rst)
            scroll <= 12'd0;
        else if (frame_start) begin
            if (scroll >= 12'd2304)
                scroll <= 12'd0;
            else
                scroll <= scroll + 12'd3;
        end
    end

    wire        sub_bar = (y >= VACTIVE - 104) && (y < VACTIVE - 40);
    wire [13:0] sub_x   = {2'b00, x} + {2'b00, scroll};
    wire [13:0] sub_tx  = sub_x - 14'd24;
    wire        sub_tv  = (y >= VACTIVE - 96) && (y < VACTIVE - 64);
    wire        sub_hv  = sub_tv && (sub_tx < 14'd1024);

    // ------------------------------------------------------------------
    // 字模索引
    // ------------------------------------------------------------------
    function [5:0] g_title;
        input [1:0] i;
        begin
            case (i)
                2'd0: g_title = 6'd42;   // 调
                2'd1: g_title = 6'd43;   // 试
                2'd2: g_title = 6'd44;   // 菜
                default: g_title = 6'd45; // 单
            endcase
        end
    endfunction

    function [5:0] g_label;
        input [2:0] it;
        input [1:0] i;
        begin
            g_label = 6'd37;             // 空格
            case (it)
                3'd0: case (i)
                    2'd0: g_label = 6'd46;   // 切
                    2'd1: g_label = 6'd47;   // 屏
                    2'd2: g_label = 6'd48;   // 效
                    default: g_label = 6'd49; // 果
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
                    2'd0: g_label = 6'd58;   // 字
                    2'd1: g_label = 6'd59;   // 幕
                    default: g_label = 6'd37;
                endcase
                default: case (i)
                    2'd0: g_label = 6'd60;   // 音
                    2'd1: g_label = 6'd61;   // 量
                    default: g_label = 6'd37;
                endcase
            endcase
        end
    endfunction

    function [5:0] g_hint;
        input [4:0] i;
        begin
            case (i)
                5'd0:  g_hint = 6'd14;   // O
                5'd1:  g_hint = 6'd10;   // K
                5'd2:  g_hint = 6'd37;
                5'd3:  g_hint = 6'd13;   // N
                5'd4:  g_hint = 6'd4;    // E
                5'd5:  g_hint = 6'd23;   // X
                5'd6:  g_hint = 6'd19;   // T
                5'd7:  g_hint = 6'd37;
                5'd8:  g_hint = 6'd37;
                5'd9:  g_hint = 6'd12;   // M
                5'd10: g_hint = 6'd4;    // E
                5'd11: g_hint = 6'd13;   // N
                5'd12: g_hint = 6'd20;   // U
                5'd13: g_hint = 6'd37;
                5'd14: g_hint = 6'd4;    // E
                5'd15: g_hint = 6'd23;   // X
                5'd16: g_hint = 6'd8;    // I
                default: g_hint = 6'd19; // T
            endcase
        end
    endfunction

    // 字幕文案： "NOW PLAYING 01/12  MUSIC FRAME   "
    function [5:0] g_sub;
        input [4:0] i;
        begin
            case (i)
                5'd0:  g_sub = 6'd13;  // N
                5'd1:  g_sub = 6'd14;  // O
                5'd2:  g_sub = 6'd22;  // W
                5'd3:  g_sub = 6'd37;  //
                5'd4:  g_sub = 6'd15;  // P
                5'd5:  g_sub = 6'd11;  // L
                5'd6:  g_sub = 6'd0;   // A
                5'd7:  g_sub = 6'd24;  // Y
                5'd8:  g_sub = 6'd8;   // I
                5'd9:  g_sub = 6'd13;  // N
                5'd10: g_sub = 6'd6;   // G
                5'd11: g_sub = 6'd37;
                5'd12: g_sub = 6'd26;  // 0
                5'd13: g_sub = 6'd27;  // 1
                5'd14: g_sub = 6'd38;  // /
                5'd15: g_sub = 6'd27;  // 1
                5'd16: g_sub = 6'd28;  // 2
                5'd17: g_sub = 6'd37;
                5'd18: g_sub = 6'd37;
                5'd19: g_sub = 6'd12;  // M
                5'd20: g_sub = 6'd20;  // U
                5'd21: g_sub = 6'd18;  // S
                5'd22: g_sub = 6'd8;   // I
                5'd23: g_sub = 6'd2;   // C
                5'd24: g_sub = 6'd37;
                5'd25: g_sub = 6'd5;   // F
                5'd26: g_sub = 6'd17;  // R
                5'd27: g_sub = 6'd0;   // A
                5'd28: g_sub = 6'd12;  // M
                5'd29: g_sub = 6'd4;   // E
                default: g_sub = 6'd37;
            endcase
        end
    endfunction

    function [5:0] g_val;
        input [2:0] it;
        input [2:0] i;
        input [3:0] v;
        begin
            g_val = 6'd37;
            case (it)
                3'd0: begin                       // FADE / SLIDE / WIPE / CUT
                    case (i)
                        3'd0: g_val = (v == 4'd0) ? 6'd5 : (v == 4'd1) ? 6'd18 : (v == 4'd2) ? 6'd22 : 6'd2;
                        3'd1: g_val = (v == 4'd0) ? 6'd0 : (v == 4'd1) ? 6'd11 : (v == 4'd2) ? 6'd8  : 6'd20;
                        3'd2: g_val = (v == 4'd0) ? 6'd3 : (v == 4'd1) ? 6'd8  : (v == 4'd2) ? 6'd15 : 6'd19;
                        3'd3: g_val = (v == 4'd0) ? 6'd4 : (v == 4'd1) ? 6'd3  : (v == 4'd2) ? 6'd4  : 6'd37;
                        3'd4: g_val = (v == 4'd1) ? 6'd4 : 6'd37;
                        default: g_val = 6'd37;
                    endcase
                end
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
                3'd4: begin                       // ON / OFF
                    case (i)
                        3'd0: g_val = 6'd14;                       // O
                        3'd1: g_val = v[0] ? 6'd13 : 6'd5;         // N / F
                        3'd2: g_val = v[0] ? 6'd37 : 6'd5;         // - / F
                        default: g_val = 6'd37;
                    endcase
                end
                default: begin                    // 百分比：0% / 80% / 100%
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
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 第一级：区域底色 + 文本请求
    // ------------------------------------------------------------------
    reg        s0_text;
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

        // ---- 菜单底色 ----
        if (open) begin
            if (!in_panel) begin
                s0_base_rgb   = C_MASK;
                s0_base_alpha = 4'd3;              // 全屏 37.5% 黑遮罩
            end else if (in_border) begin
                s0_base_rgb   = C_BORDER;
                s0_base_alpha = 4'd8;
            end else if (row_band && (ridx == item)) begin
                s0_base_rgb   = C_HLBG;
                s0_base_alpha = 4'd8;
            end else begin
                s0_base_rgb   = C_PANEL;
                s0_base_alpha = 4'd8;
            end
        end

        // ---- 字幕条底（半透明黑） ----
        if (sub_on && sub_bar) begin
            s0_base_rgb   = 24'h00_00_00;
            s0_base_alpha = 4'd5;
        end

        // ---- 文本：菜单优先，其次字幕 ----
        if (open && title_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_title(tcx[6:5]);
            s0_fcol   = tcx[4:1];
            s0_frow   = (y - (PY0 + 24)) >> 1;
            s0_tcolor = C_TITLE;
        end else if (open && label_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_label(ridx, lcx[6:5]);
            s0_fcol   = lcx[4:1];
            s0_frow   = row_fr;
            s0_tcolor = C_LABEL;
        end else if (open && value_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_val(ridx, vcx[7:5], row_val);
            s0_fcol   = vcx[4:1];
            s0_frow   = row_fr;
            s0_tcolor = C_VALUE;
        end else if (open && hint_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_hint(hcx[8:4]);
            s0_fcol   = hcx[3:0];
            s0_frow   = y - (PY0 + PH - 40);
            s0_tcolor = C_HINT;
        end else if (sub_on && sub_hv) begin
            s0_text   = 1'b1;
            s0_glyph  = g_sub(sub_tx[9:5]);
            s0_fcol   = sub_tx[4:1];
            s0_frow   = (y - (VACTIVE - 96)) >> 1;
            s0_tcolor = 24'hFF_FF_FF;
        end
    end

    // ------------------------------------------------------------------
    // 第二级：字模 ROM
    // ------------------------------------------------------------------
    reg        s1_text;
    reg [3:0]  s1_fcol;
    reg [23:0] s1_tcolor;
    reg [23:0] s1_base_rgb;
    reg [3:0]  s1_base_alpha;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s1_text       <= 1'b0;
            s1_fcol       <= 4'd0;
            s1_tcolor     <= 24'd0;
            s1_base_rgb   <= 24'd0;
            s1_base_alpha <= 4'd0;
        end else begin
            s1_text       <= s0_text;
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
    reg [3:0]  s2_fcol;
    reg [23:0] s2_tcolor;
    reg [23:0] s2_base_rgb;
    reg [3:0]  s2_base_alpha;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2_text       <= 1'b0;
            s2_fcol       <= 4'd0;
            s2_tcolor     <= 24'd0;
            s2_base_rgb   <= 24'd0;
            s2_base_alpha <= 4'd0;
        end else begin
            s2_text       <= s1_text;
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
            osd_on    <= 1'b1;
            osd_rgb   <= s2_tcolor;
            osd_alpha <= 4'd8;
        end else begin
            osd_on    <= (s2_base_alpha != 4'd0);
            osd_rgb   <= s2_base_rgb;
            osd_alpha <= s2_base_alpha;
        end
    end

endmodule
