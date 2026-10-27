// ============================================================================
//  key_ctrl.v —— 按键同步 / 去抖 / 长按连发
//
//  按键低有效（板上按键按下为 0）
//  press : 按下瞬间单拍
//  rep   : 长按 REPEAT_DELAY 后，每 1/REPEAT_HZ 秒一个单拍
// ============================================================================
`timescale 1ns / 1ps

module key_one #(
    parameter integer CLK_HZ       = 75_000_000,
    parameter integer DEBOUNCE_MS  = 20,
    parameter integer REPEAT_DELAY_MS = 500,
    parameter integer REPEAT_HZ    = 10
)(
    input  wire clk,
    input  wire rst,
    input  wire key,          // 低有效
    output reg  press,
    output reg  rep
);

    localparam integer DEB_CYC = CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer RDL_CYC = CLK_HZ / 1000 * REPEAT_DELAY_MS;
    localparam integer RPT_CYC = CLK_HZ / REPEAT_HZ;

    reg [1:0]  sync;
    reg        stable;
    reg [31:0] db_cnt;
    reg [31:0] hold_cnt;
    reg [31:0] rep_cnt;
    reg        rep_armed;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync      <= 2'b11;
            stable    <= 1'b1;
            db_cnt    <= 32'd0;
            hold_cnt  <= 32'd0;
            rep_cnt   <= 32'd0;
            rep_armed <= 1'b0;
            press     <= 1'b0;
            rep       <= 1'b0;
        end else begin
            sync   <= {sync[0], key};
            press  <= 1'b0;
            rep    <= 1'b0;

            // ---- 去抖 ----
            if (sync[1] == stable) begin
                db_cnt <= 32'd0;
            end else if (db_cnt >= DEB_CYC - 1) begin
                db_cnt <= 32'd0;
                stable <= sync[1];
                if (stable && !sync[1])      // 1 -> 0 即按下
                    press <= 1'b1;
            end else begin
                db_cnt <= db_cnt + 32'd1;
            end

            // ---- 长按连发 ----
            if (stable) begin                    // 松开
                hold_cnt  <= 32'd0;
                rep_cnt   <= 32'd0;
                rep_armed <= 1'b0;
            end else if (!rep_armed) begin
                if (hold_cnt >= RDL_CYC - 1) begin
                    rep_armed <= 1'b1;
                    hold_cnt  <= 32'd0;
                    rep       <= 1'b1;        // 到达延时先发一次
                end else begin
                    hold_cnt <= hold_cnt + 32'd1;
                end
            end else begin
                if (rep_cnt >= RPT_CYC - 1) begin
                    rep_cnt <= 32'd0;
                    rep     <= 1'b1;
                end else begin
                    rep_cnt <= rep_cnt + 32'd1;
                end
            end
        end
    end

endmodule


module key_ctrl #(
    parameter integer CLK_HZ = 75_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [3:0] key_in,     // {OK, DOWN, UP, MENU}
    output wire [3:0] press,
    output wire [3:0] rep
);

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_key
            key_one #(.CLK_HZ(CLK_HZ)) u_key (
                .clk   (clk),
                .rst   (rst),
                .key   (key_in[i]),
                .press (press[i]),
                .rep   (rep[i])
            );
        end
    endgenerate

endmodule


// ============================================================================
//  nav_ctrl.v（并入本文件）—— 图片切换的"计时 + 按键挂起"逻辑
//
//  设计原则（这里只做决定，不碰帧缓存/SD）：
//    1) 手动优先：KEY1/KEY2 一旦按下就挂起，等画面回到"正常显示"
//       （showing=1）再执行。加载/转场期间按键不会丢 —— 上板反馈的
//       "按上下键没反应"就是因为脉冲落在 LOAD 里被吃掉了。
//    2) 自动轮播必须 auto_en=1 才累计；关掉时计数恒 0，
//       所以"轮播 OFF 却自己切图"在结构上不可能发生。
//    3) 档位一变（hold_sel != hold_d）立刻清零，重新从头计时。
//       否则改档位时会拿旧计数去比新阈值，看起来像"一改就切"。
//    4) 每切一次（不论手动还是自动）计数归零，间隔从新图开始算。
// ============================================================================
module nav_ctrl #(
    parameter integer FRAME_HZ = 30          // 只用于注释：hold 档位按帧数算
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_tick,   // 帧首单拍
    input  wire        showing,      // 1 = 正在正常显示（可接受切图）
    input  wire        auto_en,      // 菜单里的轮播开关
    input  wire [2:0]  hold_sel,     // 0..4 -> 3/5/8/15/30 秒
    input  wire        key_next,     // KEY2：下一张
    input  wire        key_prev,     // KEY1：上一张
    output reg         step,         // 切图单拍
    output reg         step_prev,    // 1 = 上一张
    output reg  [15:0] hold_cnt      // 调试观测
);

    // 30fps 下的帧数：90/150/240/450/900
    wire [15:0] hold_lim = (hold_sel == 3'd0) ? 16'd90  :
                           (hold_sel == 3'd1) ? 16'd150 :
                           (hold_sel == 3'd2) ? 16'd240 :
                           (hold_sel == 3'd3) ? 16'd450 : 16'd900;

    reg        pend;
    reg        pend_dir;
    reg [2:0]  hold_d;

    // 手动：有挂起且画面正常显示 -> 立刻执行
    wire man_due = pend & showing;
    // 自动：开关打开 + 显示中 + 计数到点
    wire auto_due = auto_en & showing & (hold_cnt >= hold_lim);
    wire go       = man_due | auto_due;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            step      <= 1'b0;
            step_prev <= 1'b0;
            pend      <= 1'b0;
            pend_dir  <= 1'b0;
            hold_cnt  <= 16'd0;
            hold_d    <= 3'd0;
        end else begin
            step      <= go;
            step_prev <= go & (man_due ? pend_dir : 1'b0);

            // ---- 按键挂起（按住不放时由上层 rep 连发覆盖方向）----
            if (key_next) begin
                pend     <= 1'b1;
                pend_dir <= 1'b0;
            end else if (key_prev) begin
                pend     <= 1'b1;
                pend_dir <= 1'b1;
            end else if (man_due) begin
                pend     <= 1'b0;
            end

            // ---- 间隔计数 ----
            if (hold_sel != hold_d) begin
                hold_d   <= hold_sel;
                hold_cnt <= 16'd0;                  // 改档位：重新计时
            end else if (!auto_en) begin
                hold_cnt <= 16'd0;                  // 轮播关：永不累计
            end else if (go) begin
                hold_cnt <= 16'd0;                  // 刚切过：从新图重新计
            end else if (showing && frame_tick && (hold_cnt < hold_lim)) begin
                hold_cnt <= hold_cnt + 16'd1;
            end
        end
    end

endmodule
