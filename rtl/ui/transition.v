// ============================================================================
//  transition.v —— 转场引擎（两路同坐标视频之间）
//
//  effect: 0=FADE 淡入淡出   1=SLIDE 软边推进
//          2=WIPE 硬边擦除   3=CUT   直接切换
//  prog  : 0..255，0 全 A，255 全 B
//
//  注：SLIDE/WIPE 按屏幕坐标做边界选择，不做内容平移（真平移需要行缓冲）。
// ============================================================================
`timescale 1ns / 1ps

module transition #(
    parameter integer HACTIVE = 1280
)(
    input  wire [23:0] rgb_a,
    input  wire [23:0] rgb_b,
    input  wire [11:0] x,
    input  wire [1:0]  effect,
    input  wire [7:0]  prog,
    output reg  [23:0] rgb_out
);

    // ---------------- FADE ----------------
    function [7:0] mix8;
        input [7:0] a;
        input [7:0] b;
        input [7:0] p;
        reg signed [8:0] d;
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

    wire [23:0] fade_rgb = { mix8(rgb_a[23:16], rgb_b[23:16], prog),
                             mix8(rgb_a[15:8],  rgb_b[15:8],  prog),
                             mix8(rgb_a[7:0],   rgb_b[7:0],   prog) };

    // ---------------- 边界推进 ----------------
    // A 占左边、B 从右侧推入：prog=0 -> split=HACTIVE（全 A），
    // prog=255 -> split≈0（全 B），与 FADE 的语义一致
    wire [19:0] split_p = prog * HACTIVE;
    wire [11:0] split_x = HACTIVE[11:0] - split_p[19:8];

    // SLIDE：32 像素软边
    wire [12:0] pos32 = {1'b0, x} - {1'b0, split_x};
    reg  [23:0] slide_rgb;
    always @(*) begin
        if (x < split_x)
            slide_rgb = rgb_a;
        else if (x < split_x + 12'd32)
            // 软边：按位置线性混合，alpha = 偏移 x 8
            slide_rgb = { mix8(rgb_a[23:16], rgb_b[23:16], {pos32[4:0], 3'b000}),
                          mix8(rgb_a[15:8],  rgb_b[15:8],  {pos32[4:0], 3'b000}),
                          mix8(rgb_a[7:0],   rgb_b[7:0],   {pos32[4:0], 3'b000}) };
        else
            slide_rgb = rgb_b;
    end

    // WIPE：硬边
    wire [23:0] wipe_rgb = (x < split_x) ? rgb_a : rgb_b;

    always @(*) begin
        case (effect)
            2'd0:    rgb_out = fade_rgb;
            2'd1:    rgb_out = slide_rgb;
            2'd2:    rgb_out = wipe_rgb;
            default: rgb_out = (prog < 8'd128) ? rgb_a : rgb_b;
        endcase
    end

endmodule


// ============================================================================
//  auto_transition.v —— 自动转场节拍：每 HOLD 帧跑一次，A/B 角色交替
// ============================================================================
module auto_transition #(
    parameter integer HOLD_FRAMES = 150,   // 每种画面停留帧数
    parameter integer RUN_FRAMES  = 32     // 转场持续帧数
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       frame_tick,          // 帧首单拍
    input  wire       trig,                // 手动触发（按键）
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
        end else if (frame_tick) begin
            if (!running) begin
                if ((hold_cnt >= HOLD_FRAMES) || trig) begin
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
                    prog    <= 8'd0;      // 与新 swap 后的 src_a 对应，画面不跳
                    swap    <= ~swap;
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
