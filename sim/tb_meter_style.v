`timescale 1ns / 1ps
module tb_meter_style;
    reg clk = 1'b0;
    always #13.333 clk = ~clk;
    reg rst = 1'b1;

    reg  [11:0] x = 12'd0, y = 12'd0;
    wire [255:0] bars;
    wire m_on;
    wire [23:0] m_rgb;
    wire [3:0]  m_alpha;

    // 一个有起伏的频谱包络
    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : gen_bars
            localparam integer V = (gi < 4)  ? 210 - gi*18 :
                                   (gi < 10) ? 150 + ((gi*37) % 90) :
                                   (gi < 20) ? 200 - (gi-10)*12 :
                                               (gi < 28) ? 90 + ((gi*29) % 70) : 40 + (gi % 20);
            assign bars[gi*8 +: 8] = V[7:0];
        end
    endgenerate

    reg style_r = 1'b1;          // 1=圆形，0=条形（两遍渲染，分别出图）

    audio_meter #(.X0(128), .Y0(468), .BARW(32), .NBAR(32), .MAXH(112)) u_m (
        .clk(clk), .rst(rst),
        .x(x), .y(y), .bars(bars), .enable(1'b1), .style(style_r),
        .on(m_on), .rgb(m_rgb), .alpha(m_alpha)
    );

    reg [23:0] img [0:1280*720-1];
    integer i, j, k;
    initial begin
        #200 rst = 1'b0;
        for (j = 0; j < 720; j = j + 1) begin
            for (i = 0; i < 1280; i = i + 1) begin
                x <= i[11:0];
                y <= j[11:0];
                @(posedge clk);
                #1;
                img[j*1280+i] = m_on ? m_rgb : 24'h10_18_20;
            end
        end
        k = $fopen("meter_circ.ppm", "wb");
        $fwrite(k, "P6\n1280 720\n255\n");
        for (i = 0; i < 1280*720; i = i + 1) begin
            $fwrite(k, "%c%c%c", img[i][23:16], img[i][15:8], img[i][7:0]);
        end
        $fclose(k);

        // ---- 再渲染一遍 BAR 样式（只抓音频条那一条区域），确认彩虹表没被改坏 ----
        style_r = 1'b0;
        repeat (4) @(posedge clk);
        k = $fopen("meter_bar.ppm", "wb");
        $fwrite(k, "P6\n1024 140\n255\n");
        for (j = 460; j < 600; j = j + 1) begin
            for (i = 128; i < 1152; i = i + 1) begin
                x <= i[11:0];
                y <= j[11:0];
                @(posedge clk);
                #1;
                $fwrite(k, "%c%c%c", m_on ? m_rgb[23:16] : 8'h10,
                                      m_on ? m_rgb[15:8]  : 8'h18,
                                      m_on ? m_rgb[7:0]   : 8'h20);
            end
        end
        $fclose(k);
        $display("done");
        $finish;
    end
endmodule
