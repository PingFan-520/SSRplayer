// ============================================================================
//  tone_gen.v —— HDMI 音频源（DDS 正弦音调）
//
//  目的：赛题基础要求里有"基础音频输出"，原来 HDMI 核的音频接口一直接 0。
//        这里用 DDS 产生一个随图片编号变化的单音，既是音频输出，
//        又能体现"音视频联动"（换图变调）。
//
//  时钟：像素时钟 37.5MHz（与 HDMI 核同域），采样率 48kHz
//    采样节拍用 32 位累加器 + 进位：每拍加 5498，
//    实际采样率 = 37.5MHz x 5498 / 2^32 = 48003Hz（误差 0.006%）
//
//  音高：800 + img_idx*200 Hz（img_idx 0..7 -> 800..2200Hz）
//    相位增量 = freq x 2^32 / 48000
//
//  正弦表：64 点、16 位有符号，取相位累加器高 6 位
// ============================================================================
`timescale 1ns / 1ps

module tone_gen #(
    parameter integer CLK_HZ    = 37_500_000,
    parameter integer SAMPLE_HZ = 48_000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  note_idx,     // 由当前图片编号决定音高（换图变调）
    input  wire        mute,         // 1 = 静音

    output reg         aud_valid,    // 采样有效（单拍）
    output reg  [23:0] aud_left,
    output reg  [23:0] aud_right
);

    // ------------------------------------------------------------------
    // 48kHz 采样节拍：32 位累加器 + 进位
    //   5498 = round(48000 * 2^32 / 37500000)
    // ------------------------------------------------------------------
    reg [32:0] smp_acc;

    always @(posedge clk or posedge rst) begin
        if (rst) smp_acc <= 33'd0;
        else     smp_acc <= smp_acc[31:0] + 32'd5498;
    end

    wire smp_tick = smp_acc[32];

    // ------------------------------------------------------------------
    // 音高 -> 相位增量（freq * 2^32 / 48000）
    //   2^32 / 48000 = 89478.485
    // ------------------------------------------------------------------
    reg [31:0] phase_inc;

    always @(*) begin
        case (note_idx[2:0])
            3'd0:    phase_inc = 32'd71582788;    //  800 Hz
            3'd1:    phase_inc = 32'd89478485;    // 1000 Hz
            3'd2:    phase_inc = 32'd107374182;   // 1200 Hz
            3'd3:    phase_inc = 32'd125269879;   // 1400 Hz
            3'd4:    phase_inc = 32'd143165576;   // 1600 Hz
            3'd5:    phase_inc = 32'd161061273;   // 1800 Hz
            3'd6:    phase_inc = 32'd178956970;   // 2000 Hz
            default: phase_inc = 32'd196852667;   // 2200 Hz
        endcase
    end

    reg [31:0] ph;

    always @(posedge clk or posedge rst) begin
        if (rst)                 ph <= 32'd0;
        else if (smp_tick)       ph <= ph + phase_inc;
    end

    // ------------------------------------------------------------------
    // 64 点正弦表（取相位高 6 位）
    // ------------------------------------------------------------------
    reg signed [15:0] sin_q;

    always @(*) begin
        case (ph[31:26])
                6'd0 : sin_q = 16'sh0000;
                6'd1 : sin_q = 16'sh0C8C;
                6'd2 : sin_q = 16'sh18F9;
                6'd3 : sin_q = 16'sh2528;
                6'd4 : sin_q = 16'sh30FB;
                6'd5 : sin_q = 16'sh3C56;
                6'd6 : sin_q = 16'sh471C;
                6'd7 : sin_q = 16'sh5133;
                6'd8 : sin_q = 16'sh5A82;
                6'd9 : sin_q = 16'sh62F1;
                6'd10: sin_q = 16'sh6A6D;
                6'd11: sin_q = 16'sh70E2;
                6'd12: sin_q = 16'sh7641;
                6'd13: sin_q = 16'sh7A7C;
                6'd14: sin_q = 16'sh7D89;
                6'd15: sin_q = 16'sh7F61;
                6'd16: sin_q = 16'sh7FFF;
                6'd17: sin_q = 16'sh7F61;
                6'd18: sin_q = 16'sh7D89;
                6'd19: sin_q = 16'sh7A7C;
                6'd20: sin_q = 16'sh7641;
                6'd21: sin_q = 16'sh70E2;
                6'd22: sin_q = 16'sh6A6D;
                6'd23: sin_q = 16'sh62F1;
                6'd24: sin_q = 16'sh5A82;
                6'd25: sin_q = 16'sh5133;
                6'd26: sin_q = 16'sh471C;
                6'd27: sin_q = 16'sh3C56;
                6'd28: sin_q = 16'sh30FB;
                6'd29: sin_q = 16'sh2528;
                6'd30: sin_q = 16'sh18F9;
                6'd31: sin_q = 16'sh0C8C;
                6'd32: sin_q = 16'sh0000;
                6'd33: sin_q = 16'shF374;
                6'd34: sin_q = 16'shE707;
                6'd35: sin_q = 16'shDAD8;
                6'd36: sin_q = 16'shCF05;
                6'd37: sin_q = 16'shC3AA;
                6'd38: sin_q = 16'shB8E4;
                6'd39: sin_q = 16'shAECD;
                6'd40: sin_q = 16'shA57E;
                6'd41: sin_q = 16'sh9D0F;
                6'd42: sin_q = 16'sh9593;
                6'd43: sin_q = 16'sh8F1E;
                6'd44: sin_q = 16'sh89BF;
                6'd45: sin_q = 16'sh8584;
                6'd46: sin_q = 16'sh8277;
                6'd47: sin_q = 16'sh809F;
                6'd48: sin_q = 16'sh8001;
                6'd49: sin_q = 16'sh809F;
                6'd50: sin_q = 16'sh8277;
                6'd51: sin_q = 16'sh8584;
                6'd52: sin_q = 16'sh89BF;
                6'd53: sin_q = 16'sh8F1E;
                6'd54: sin_q = 16'sh9593;
                6'd55: sin_q = 16'sh9D0F;
                6'd56: sin_q = 16'shA57E;
                6'd57: sin_q = 16'shAECD;
                6'd58: sin_q = 16'shB8E4;
                6'd59: sin_q = 16'shC3AA;
                6'd60: sin_q = 16'shCF05;
                6'd61: sin_q = 16'shDAD8;
                6'd62: sin_q = 16'shE707;
                6'd63: sin_q = 16'shF374;
                default: sin_q = 16'sh0000;
        endcase
    end

    // ------------------------------------------------------------------
    // 输出：24 位采样（16 位正弦左移 6 位，即 1/2 幅度）
    //   aud_valid 与数据同拍（smp_tick 寄存一拍）
    // ------------------------------------------------------------------
    wire [23:0] sample = { {2{sin_q[15]}}, sin_q, 6'd0 };

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            aud_valid <= 1'b0;
            aud_left  <= 24'd0;
            aud_right <= 24'd0;
        end else begin
            aud_valid <= smp_tick;
            aud_left  <= mute ? 24'd0 : sample;
            aud_right <= mute ? 24'd0 : sample;
        end
    end

endmodule
