`timescale 1ns / 1ps
// ============================================================================
//  tb_scale34.v —— bmp_scale 的 3/4 精确抽取验证（1280x720 -> 960x540）
//  每个源像素写唯一值 pat(sx,sy)，检查：
//    1) 输出像素数 = 960*540；
//    2) 每个目标坐标恰好被写一次（无重叠/空洞）；
//    3) 目标值 = pat( (tx/3)*4 + tx%3, (ty/3)*4 + ty%3 )
// ============================================================================
module tb_scale34;

    reg clk = 1'b0;
    always #13.3333 clk = ~clk;              // 37.5MHz
    reg rst = 1'b1;
    initial #200 rst = 1'b0;

    reg         s_we = 1'b0;
    reg  [11:0] s_sx = 12'd0, s_sy = 12'd0;
    reg  [15:0] s_rgb = 16'd0;
    reg         o_rdy = 1'b1;

    wire        o_we;
    wire [11:0] o_x, o_y;
    wire [15:0] o_rgb;
    wire [2:0]  o_k;

    bmp_scale #(.DW(960), .DH(540)) dut (
        .clk(clk), .rst(rst),
        .s_we(s_we), .s_sx(s_sx), .s_sy(s_sy), .s_rgb(s_rgb),
        .img_w(16'd1280), .img_h(16'd720), .mode(2'd0),
        .clr(1'b0), .clr_done(), .clr_busy(),
        .o_rdy(o_rdy), .o_we(o_we), .o_x(o_x), .o_y(o_y), .o_rgb(o_rgb),
        .o_k(o_k)
    );

    function [15:0] pat;
        input integer px, py;
        begin
            pat = ((px * 3 + py * 7) & 16'hFFFF);
        end
    endfunction

    reg [15:0] cap [0:960*540-1];
    reg [7:0]  hit [0:960*540-1];
    integer i, x, y, n, bad_v, bad_h, bad_coord, perr;

    initial begin
        for (i = 0; i < 960*540; i = i + 1) begin
            cap[i] = 16'hDEAD;
            hit[i] = 8'd0;
        end
        wait (!rst);
        repeat (10) @(posedge clk);

        for (y = 0; y < 720; y = y + 1) begin
            for (x = 0; x < 1280; x = x + 1) begin
                @(negedge clk);
                s_we  = 1'b1;
                s_sx  = x[11:0];
                s_sy  = y[11:0];
                s_rgb = pat(x, y);
            end
        end
        @(negedge clk);
        s_we = 1'b0;
        repeat (20) @(posedge clk);

        n = 0;
        for (i = 0; i < 960*540; i = i + 1)
            if (hit[i] != 0) n = n + 1;
        $display("[res] covered %0d / %0d target pixels", n, 960*540);

        bad_v = 0; bad_h = 0; bad_coord = 0; perr = 0;
        for (i = 0; i < 960*540; i = i + 1) begin
            if (hit[i] > 1) bad_coord = bad_coord + 1;
            if (hit[i] == 0) bad_v = bad_v + 1;
        end
        for (y = 0; y < 540; y = y + 1) begin
            for (x = 0; x < 960; x = x + 1) begin
                if (cap[y*960+x] !== pat((x/3)*4 + (x%3), (y/3)*4 + (y%3))) begin
                    if (perr < 8)
                        $display("[m] (%0d,%0d) got=%h exp=%h", x, y, cap[y*960+x],
                                 pat((x/3)*4 + (x%3), (y/3)*4 + (y%3)));
                    perr = perr + 1;
                    bad_h = bad_h + 1;
                end
            end
        end
        $display("[res] missing=%0d multi=%0d value_bad=%0d", bad_v, bad_coord, bad_h);
        if (n == 960*540 && bad_v == 0 && bad_coord == 0 && bad_h == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end

    // 采集（o_we 单拍，o_x/o_y 同为寄存输出）
    always @(posedge clk) begin
        if (o_we) begin
            cap[o_y*960 + o_x] <= o_rgb;
            hit[o_y*960 + o_x] <= hit[o_y*960 + o_x] + 8'd1;
        end
    end

endmodule
