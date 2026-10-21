// ============================================================================
//  color_bar_hd.v —— 参数化视频时序 + 彩条测试图
//
//  与参考工程 color_bar.v 端口完全一致，可直接替换：
//      color_bar  ->  color_bar_hd #(.HACTIVE(1280), ...) u_color_bar (...)
//
//  内部同时产生 hs / vs / de，替换后无需改 video_timing_data 的连接。
//  hs / vs / de / rgb 全部组合输出、严格对齐，无额外延迟。
// ============================================================================
`timescale 1ns / 1ps

module color_bar_hd #(
    // 默认 1280x720@60（像素时钟 75.000MHz）
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
    parameter integer BOX     = 96       // 移动方块边长
)(
    input  wire       clk,
    input  wire       rst,
    output wire       hs,
    output wire       vs,
    output wire       de,
    output wire [7:0] rgb_r,
    output wire [7:0] rgb_g,
    output wire [7:0] rgb_b,
    output wire [11:0] o_hcnt,
    output wire [11:0] o_vcnt
);

    localparam integer H_START = HSA + HBP;
    localparam integer V_START = VSA + VBP;
    localparam integer BAR_W   = HACTIVE / 8;

    reg [11:0] hcnt;
    reg [11:0] vcnt;

    wire h_last = (hcnt == HTOTAL - 1);
    wire v_last = (vcnt == VTOTAL - 1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcnt <= 12'd0;
            vcnt <= 12'd0;
        end else if (h_last) begin
            hcnt <= 12'd0;
            vcnt <= v_last ? 12'd0 : (vcnt + 12'd1);
        end else begin
            hcnt <= hcnt + 12'd1;
        end
    end

    wire in_h = (hcnt >= H_START) && (hcnt < H_START + HACTIVE);
    wire in_v = (vcnt >= V_START) && (vcnt < V_START + VACTIVE);

    assign hs = (hcnt < HSA);
    assign vs = (vcnt < VSA);
    assign de = in_h && in_v;

    assign o_hcnt = hcnt;
    assign o_vcnt = vcnt;

    wire [11:0] px = hcnt - H_START;
    wire [11:0] py = vcnt - V_START;

    // ------------------------------------------------------------------
    // 8 段彩条（比较器链，避免除法器）
    // ------------------------------------------------------------------
    reg [23:0] bar;
    always @(*) begin
        if      (px < BAR_W * 1) bar = 24'hFF_FF_FF;   // 白
        else if (px < BAR_W * 2) bar = 24'hFF_FF_00;   // 黄
        else if (px < BAR_W * 3) bar = 24'h00_FF_FF;   // 青
        else if (px < BAR_W * 4) bar = 24'h00_FF_00;   // 绿
        else if (px < BAR_W * 5) bar = 24'hFF_00_FF;   // 品红
        else if (px < BAR_W * 6) bar = 24'hFF_00_00;   // 红
        else if (px < BAR_W * 7) bar = 24'h00_00_FF;   // 蓝
        else                     bar = 24'h00_00_00;   // 黑
    end

    // ------------------------------------------------------------------
    // 每帧右移 8 像素的方块（证明帧在刷新，不是静止画面）
    // ------------------------------------------------------------------
    reg [11:0] box_x;
    reg        v_last_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            box_x    <= 12'd0;
            v_last_d <= 1'b0;
        end else begin
            v_last_d <= v_last;
            if (v_last && !v_last_d) begin
                if (box_x + BOX >= HACTIVE) box_x <= 12'd0;
                else                        box_x <= box_x + 12'd8;
            end
        end
    end

    wire in_box  = in_h && in_v &&
                   (px >= box_x) && (px < box_x + BOX) &&
                   (py >= (VACTIVE - BOX - 48)) && (py < (VACTIVE - 48));

    // 底部 24 行灰度渐变
    wire in_gray = in_h && in_v && (py >= VACTIVE - 24);
    wire [7:0] gray = {px[7:2], 2'b00} + {2'b00, px[7:2], 2'b00};

    assign {rgb_r, rgb_g, rgb_b} = in_box  ? 24'h00_00_00 :
                                   in_gray ? {gray, gray, gray} :
                                             bar;

endmodule
