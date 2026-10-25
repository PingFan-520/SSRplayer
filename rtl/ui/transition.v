// ============================================================================
//  transition.v —— 转场引擎（两路同坐标视频之间）
//
//  effect: 0=FADE 淡入淡出   1=SLIDE 软边推进
//          2=WIPE 硬边擦除   3=CUT   直接切换
//  prog  : 0..255，0 全 A，255 全 B
//
//  时序：输出比输入晚 2 拍。
//    第一级：比较坐标 + 像素打拍（把计数器减法从乘法前面拆开）
//    第二级：混合 + 输出寄存器
//    split_x 由 prog 预先算好并打一拍（prog 只在帧首变），
//    像素通路上不再有 8x12 乘法。
//
//  注：SLIDE/WIPE 按屏幕坐标做边界选择，不做内容平移（真平移需要行缓冲）。
// ============================================================================
`timescale 1ns / 1ps

module transition #(
    parameter integer HACTIVE = 1280
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [23:0] rgb_a,
    input  wire [23:0] rgb_b,
    input  wire [11:0] x,
    input  wire [1:0]  effect,
    input  wire [7:0]  prog,
    output reg  [23:0] rgb_out
);

    function [7:0] mix8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] p;
        reg signed [8:0]  d;
        reg signed [17:0] pr;
        reg signed [9:0]  s;
        begin
            d  = $signed({1'b0, b}) - $signed({1'b0, a});
            pr = d * $signed({1'b0, p});
            s  = $signed({2'b00, a}) + (pr >>> 8);
            if (s < 0)       mix8 = 8'd0;
            else if (s > 255) mix8 = 8'd255;
            else              mix8 = s[7:0];
        end
    endfunction

    // ---------------- 边界预计算 ----------------
    // A 占左边、B 从右侧推入：prog=0 -> split=HACTIVE（全 A），
    // prog=255 -> split≈0（全 B），与 FADE 的语义一致
    wire [19:0] split_p = prog * HACTIVE;

    reg [11:0] split_x;
    always @(posedge clk or posedge rst) begin
        if (rst) split_x <= HACTIVE[11:0];
        else     split_x <= HACTIVE[11:0] - split_p[19:8];
    end

    // ---------------- 第一级：比较 + 打拍 ----------------
    wire [12:0] pos32 = {1'b0, x} - {1'b0, split_x};

    reg [23:0] a_r, b_r;
    reg        above_r;     // x < split_x
    reg        inedge_r;    // 落在 32px 软边内
    reg [4:0]  pos5_r;      // 软边内偏移

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_r      <= 24'd0;
            b_r      <= 24'd0;
            above_r  <= 1'b1;
            inedge_r <= 1'b0;
            pos5_r   <= 5'd0;
        end else begin
            a_r      <= rgb_a;
            b_r      <= rgb_b;
            above_r  <= (x < split_x);
            inedge_r <= (x >= split_x) && (x < split_x + 12'd32);
            pos5_r   <= pos32[4:0];
        end
    end

    // ---------------- 第二级：混合 ----------------
    wire [23:0] fade_rgb = { mix8(a_r[23:16], b_r[23:16], prog),
                             mix8(a_r[15:8],  b_r[15:8],  prog),
                             mix8(a_r[7:0],   b_r[7:0],   prog) };

    wire [23:0] slide_rgb = { mix8(a_r[23:16], b_r[23:16], {pos5_r, 3'b000}),
                              mix8(a_r[15:8],  b_r[15:8],  {pos5_r, 3'b000}),
                              mix8(a_r[7:0],   b_r[7:0],   {pos5_r, 3'b000}) };

    reg [23:0] mix_rgb;
    always @(*) begin
        case (effect)
            2'd0:    mix_rgb = fade_rgb;
            2'd1:    mix_rgb = above_r ? a_r : (inedge_r ? slide_rgb : b_r);
            2'd2:    mix_rgb = above_r ? a_r : b_r;
            default: mix_rgb = (prog < 8'd128) ? a_r : b_r;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) rgb_out <= 24'd0;
        else     rgb_out <= mix_rgb;
    end

endmodule


// ============================================================================
//  auto_transition.v —— 自动转场节拍：每 HOLD 帧跑一次，A/B 角色交替
// ============================================================================
module auto_transition #(
    parameter integer HOLD_FRAMES = 150,   // 每种画面停留帧数（ONESHOT=0 时有效）
    parameter integer RUN_FRAMES  = 32,    // 转场持续帧数
    parameter integer ONESHOT     = 0      // 1 = 只在 trig 时跑一次，结束停在 b（不 swap）
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       frame_tick,          // 帧首单拍
    input  wire       trig,                // 触发（换图/按键）
    input  wire       pre_clr,             // 立刻把 prog 归零（换图瞬间先变黑）
    input  wire [1:0] effect,
    output reg  [7:0] prog,                // 0..255
    output reg        swap                 // 0: A->B   1: B->A
);

    reg [15:0] hold_cnt;
    reg [15:0] run_cnt;
    reg        running;

    wire [15:0] run_step = (RUN_FRAMES > 1) ? (256 / RUN_FRAMES) : 256;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hold_cnt <= 16'd0;
            run_cnt  <= 16'd0;
            running  <= 1'b0;
            prog     <= 8'd0;
            swap     <= 1'b0;
        end else if (pre_clr && ONESHOT[0] && !running) begin
            prog <= 8'd0;                      // 不等 frame_tick，立刻黑
        end else if (frame_tick) begin
            if (!running) begin
                // ONESHOT：不要自动周期触发，只认 trig（换图时给一个）
                if ((!ONESHOT[0] && (hold_cnt >= HOLD_FRAMES)) || trig) begin
                    running  <= 1'b1;
                    run_cnt  <= 16'd0;
                    hold_cnt <= 16'd0;
                    prog     <= 8'd0;
                end else begin
                    hold_cnt <= hold_cnt + 16'd1;
                end
            end else begin
                if (run_cnt >= RUN_FRAMES - 1) begin
                    running <= 1'b0;
                    if (ONESHOT[0]) begin
                        prog <= 8'hFF;    // 停在 b（= 新图），下次 trig 再从 0 起
                    end else begin
                        prog <= 8'd0;     // 与新 swap 后的 src_a 对应，画面不跳
                        swap <= ~swap;
                    end
                end else begin
                    run_cnt <= run_cnt + 16'd1;
                    if (prog > 8'd255 - run_step[7:0])
                        prog <= 8'd255;
                    else
                        prog <= prog + run_step[7:0];
                end
            end
        end
    end

endmodule
