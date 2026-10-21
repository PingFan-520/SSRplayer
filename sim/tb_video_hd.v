`timescale 1ns / 1ps
// ============================================================================
//  tb_video_hd.v —— 高清视频时序自检
//  检查：每行 DE 宽度 = HACTIVE、每帧有效行数 = VACTIVE、帧周期符合 HTOTAL*VTOTAL
//  覆盖：1280x720@75MHz 与 1024x768@65MHz
// ============================================================================
module tb_video_hd;

    reg rst = 1'b1;
    initial #200 rst = 1'b0;

    // ---------------- 720p ----------------
    reg clk_a = 1'b0;
    always #6.6667 clk_a = ~clk_a;          // 75MHz

    wire        hs_a, vs_a, de_a;
    wire [7:0]  r_a, g_a, b_a;

    color_bar_hd #(
        .HACTIVE(1280), .HTOTAL(1650), .HSA(40), .HBP(220), .HFP(110),
        .VACTIVE(720),  .VTOTAL(750),  .VSA(5),  .VBP(20),  .VFP(5)
    ) u_a (
        .clk(clk_a), .rst(rst),
        .hs(hs_a), .vs(vs_a), .de(de_a),
        .rgb_r(r_a), .rgb_g(g_a), .rgb_b(b_a)
    );

    wire        ax_user_a, ax_valid_a, ax_last_a;
    wire [23:0] ax_data_a;

    rgb2axis #(.HACTIVE(1280)) u_ax_a (
        .I_clk(clk_a), .I_rst(rst),
        .I_vs(vs_a), .I_de(de_a), .I_rgb({r_a, g_a, b_a}),
        .O_video_user(ax_user_a), .O_video_valid(ax_valid_a),
        .O_video_last(ax_last_a), .O_video_data(ax_data_a)
    );

    // ---------------- 1024x768 ----------------
    reg clk_b = 1'b0;
    always #7.6923 clk_b = ~clk_b;          // 65MHz

    wire        hs_b, vs_b, de_b;
    wire [7:0]  r_b, g_b, b_b;

    color_bar_hd #(
        .HACTIVE(1024), .HTOTAL(1344), .HSA(136), .HBP(160), .HFP(24),
        .VACTIVE(768),  .VTOTAL(806),  .VSA(6),   .VBP(29),  .VFP(3)
    ) u_b (
        .clk(clk_b), .rst(rst),
        .hs(hs_b), .vs(vs_b), .de(de_b),
        .rgb_r(r_b), .rgb_g(g_b), .rgb_b(b_b)
    );

    // ---------------- 统计 ----------------
    // A
    reg        vs_a_d = 1'b0, de_a_d = 1'b0;
    integer    w_a = 0, maxw_a = 0, lines_a = 0, frame_a = 0;
    real       t_vs_a = 0.0;
    integer    last_last_a = 0;

    always @(posedge clk_a) begin
        vs_a_d <= vs_a;
        de_a_d <= de_a;

        if (de_a) begin
            w_a <= w_a + 1;
            if (w_a + 1 > maxw_a) maxw_a <= w_a + 1;
        end else if (de_a_d) begin
            lines_a <= lines_a + 1;
            w_a     <= 0;
        end

        if (vs_a && !vs_a_d) begin
            if (frame_a > 0) begin
                $display("[720p  ] frame %0d: lines=%0d  width=%0d  period=%0.3f ms (expect 720 / 1280 / 16.500)",
                         frame_a, lines_a, maxw_a, (($realtime - t_vs_a) / 1000000.0));
            end
            frame_a  <= frame_a + 1;
            lines_a  <= 0;
            maxw_a   <= 0;
            t_vs_a   = $realtime;
        end

        if (ax_last_a) last_last_a <= last_last_a + 1;
    end

    // B
    reg        vs_b_d = 1'b0, de_b_d = 1'b0;
    integer    w_b = 0, maxw_b = 0, lines_b = 0, frame_b = 0;
    real       t_vs_b = 0.0;

    always @(posedge clk_b) begin
        vs_b_d <= vs_b;
        de_b_d <= de_b;

        if (de_b) begin
            w_b <= w_b + 1;
            if (w_b + 1 > maxw_b) maxw_b <= w_b + 1;
        end else if (de_b_d) begin
            lines_b <= lines_b + 1;
            w_b     <= 0;
        end

        if (vs_b && !vs_b_d) begin
            if (frame_b > 0) begin
                $display("[1024x768] frame %0d: lines=%0d  width=%0d  period=%0.3f ms (expect 768 / 1024 / 16.662)",
                         frame_b, lines_b, maxw_b, (($realtime - t_vs_b) / 1000000.0));
            end
            frame_b <= frame_b + 1;
            lines_b <= 0;
            maxw_b  <= 0;
            t_vs_b  = $realtime;
        end
    end

    initial begin
        $display("");
        $display("========== video timing self-check ==========");
        #60000000;   // 60ms，足够跑 3 帧
        $display("[720p  ] axis_last pulses = %0d (expect ~2620 = 720 line x 3.6 frame)", last_last_a);
        $display("=============================================");
        $finish;
    end

endmodule
