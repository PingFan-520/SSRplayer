// ============================================================================
//  tone_gen.v —— HDMI 音频源（DDS 正弦 + 音阶旋律 + 包络 + 音量）
//
//  赛题基础要求 (3) "基础音频输出"；扩展要求 (5) "音频可视化" 需要
//  一个有动态的音频源 —— 常幅单音的包络是一条直线，电平表不会动。
//  所以这里改成：
//    ① 基音 800 + 图片编号 x 200 Hz（换图变调 = 音视频联动）
//    ② 8 步音阶旋律（纯比率，全是移位/加法，无查表无乘法）
//    ③ 每个音符带 起音(192 采样) + 衰减 包络 —— 电平表才会上下跳
//    ④ 菜单音量 0..10 真正控制增益（原来菜单第 6 项是死控件）
//
//  时钟：像素时钟 37.5MHz（与 HDMI 核同域），采样率 48kHz
//    采样节拍用 32 位累加器 + 进位：每拍加 5,497,558（= 48000 x 2^32 / 37.5MHz），
//    实际采样率 = 48000.0 Hz（误差 < 0.001%）
//
//  音高 -> 相位增量 = freq x 2^32 / 48000
//  正弦表：64 点、16 位有符号，取相位累加器高 6 位
//  输出：24 位采样 = 16 位正弦左移 6 位（1/2 幅度基准，再乘包络/音量）
// ============================================================================
`timescale 1ns / 1ps

module tone_gen #(
    parameter integer CLK_HZ    = 37_500_000,
    parameter integer SAMPLE_HZ = 48_000,
    parameter integer NOTE_LEN  = 6000        // 每个音符的采样数（48k/6000 = 8 音符/秒）
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  note_idx,     // 由当前图片编号决定基音（换图变调）
    input  wire [3:0]  vol,          // 菜单音量 0..10（0 = 静音）
    input  wire        mute,         // 1 = 强制静音

    output reg         aud_valid,    // 采样有效（单拍）
    output reg  [23:0] aud_left,
    output reg  [23:0] aud_right,

    output wire [7:0]  env_out       // 当前有效增益（给电平表做可视化）
);

    // ------------------------------------------------------------------
    // 48kHz 采样节拍：32 位累加器 + 进位
    //   每拍加 INC = 采样率 x 2^32 / 时钟频率
    //   37.5MHz/48kHz 时 = 48000 x 2^32 / 37500000 = 5,497,558
    //   ★ 原来写的是 5498 —— 少算 1000 倍，实际采样率只有 48Hz，
    //     而且 32 位加法还会丢进位，所以音频一直是静音（两个 bug 叠加）
    // ------------------------------------------------------------------
    localparam [63:0] SMP_INC = (SAMPLE_HZ * 64'd4294967296) / CLK_HZ;
    reg [32:0] smp_acc;

    // ★ 关键：加法必须按 33 位做，否则进位被丢掉。
    //   原来写的是 `smp_acc <= smp_acc[31:0] + 32'd5498;`
    //   —— 右侧是 32 位加法，carry 直接丢弃，smp_acc[32] 永远是 0，
    //   于是 smp_tick 一次都不产生 -> 音频完全静音（上板一直没声音就是这个）。
    always @(posedge clk or posedge rst) begin
        if (rst) smp_acc <= 33'd0;
        else     smp_acc <= {1'b0, smp_acc[31:0]} + SMP_INC[32:0];
    end

    wire smp_tick = smp_acc[32];

    // ------------------------------------------------------------------
    // 音符步进：每 NOTE_LEN 个采样走一步，8 步一循环
    // ------------------------------------------------------------------
    reg [12:0] step_cnt;
    reg [2:0]  step;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            step_cnt <= 13'd0;
            step     <= 3'd0;
        end else if (smp_tick) begin
            if (step_cnt == NOTE_LEN[12:0] - 13'd1) begin
                step_cnt <= 13'd0;
                step     <= step + 3'd1;
            end else begin
                step_cnt <= step_cnt + 13'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 基音 -> 相位增量（freq * 2^32 / 48000）
    //   2^32 / 48000 = 89478.485
    // ------------------------------------------------------------------
    reg [31:0] base_inc;

    always @(*) begin
        case (note_idx[2:0])
            3'd0:    base_inc = 32'd44739243;    //  500 Hz
            3'd1:    base_inc = 32'd53746289;    //  600 Hz
            3'd2:    base_inc = 32'd62634940;    //  700 Hz
            3'd3:    base_inc = 32'd71582788;    //  800 Hz
            3'd4:    base_inc = 32'd80530637;    //  900 Hz
            3'd5:    base_inc = 32'd89478485;    // 1000 Hz
            3'd6:    base_inc = 32'd98426334;    // 1100 Hz
            default: base_inc = 32'd107374182;   // 1200 Hz
        endcase
    end

    // ------------------------------------------------------------------
    // 旋律：8 步的比率（1, 1.5, 2, 1.25, 1, 1.5, 2, 0.5）
    //   全部用移位/加法，不查表不乘
    // ------------------------------------------------------------------
    reg [31:0] mel_inc;

    always @(*) begin
        case (step)
            3'd0:    mel_inc = base_inc;                      // 1x   主音
            3'd1:    mel_inc = base_inc + (base_inc >> 1);     // 1.5x 五度
            3'd2:    mel_inc = base_inc << 1;                  // 2x   八度
            3'd3:    mel_inc = base_inc + (base_inc >> 2);     // 1.25x 三度
            3'd4:    mel_inc = base_inc;                       // 1x
            3'd5:    mel_inc = base_inc + (base_inc >> 1);     // 1.5x
            3'd6:    mel_inc = base_inc << 1;                  // 2x
            default: mel_inc = base_inc >> 1;                  // 0.5x
        endcase
    end

    reg [31:0] ph;

    always @(posedge clk or posedge rst) begin
        if (rst)                 ph <= 32'd0;
        else if (smp_tick)       ph <= ph + mel_inc;
    end

    // ------------------------------------------------------------------
    // 包络：起音 192 采样线性升到 255，之后每 16 采样降 1（约 4080 采样后归零）
    // ------------------------------------------------------------------
    wire [12:0] over = step_cnt - 13'd192;
    wire [9:0]  decv = over[12:4];                 // (step_cnt-192)/16
    wire [7:0]  env  = (step_cnt < 13'd192) ? step_cnt[7:0] :
                       ((decv >= 10'd255) ? 8'd0 : (8'd255 - decv[7:0]));

    // ------------------------------------------------------------------
    // 菜单音量 -> 8 位增益（vol/10 的定点近似，256 = 满幅）
    // ------------------------------------------------------------------
    reg [8:0] vol_g;

    always @(*) begin
        case (vol)
            4'd0:    vol_g = 9'd0;
            4'd1:    vol_g = 9'd26;      //  10%
            4'd2:    vol_g = 9'd51;      //  20%
            4'd3:    vol_g = 9'd77;      //  30%
            4'd4:    vol_g = 9'd102;     //  40%
            4'd5:    vol_g = 9'd128;     //  50%
            4'd6:    vol_g = 9'd154;     //  60%
            4'd7:    vol_g = 9'd179;     //  70%
            4'd8:    vol_g = 9'd205;     //  80%
            4'd9:    vol_g = 9'd230;     //  90%
            default: vol_g = 9'd256;     // 100%
        endcase
    end

    wire [16:0] ge   = env * vol_g;      // 8x9 -> 17 位
    wire [7:0]  gain = mute ? 8'd0 : ge[15:8];

    assign env_out = gain;

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
    // 输出：正弦 x 增益，再左移 6 位到 24 位
    //   prod = sin_q * gain (-32768*255 .. 32767*255)
    //   scaled = prod >>> 8，仍为 16 位有符号
    // ------------------------------------------------------------------
    wire signed [23:0] prod   = sin_q * $signed({1'b0, gain});
    wire signed [15:0] scaled = prod[23:8];
    wire [23:0] sample = { {2{scaled[15]}}, scaled, 6'd0 };

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            aud_valid <= 1'b0;
            aud_left  <= 24'd0;
            aud_right <= 24'd0;
        end else begin
            aud_valid <= smp_tick;
            aud_left  <= sample;
            aud_right <= sample;
        end
    end

endmodule
