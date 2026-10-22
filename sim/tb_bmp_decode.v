`timescale 1ns / 1ps
// ============================================================================
//  tb_bmp_decode.v —— 用真实 BMP 文件验证解码器
//
//  做法：把 .bmp 读成字节数组，按 1 字节 / 2 拍喂给 bmp_decode，
//        像素写进 1280x720 的帧数组，解码完成导出 PPM。
//  比对：Python 端裁出中心 640x480，与源图逐像素比较（RGB565 量化后）。
// ============================================================================
module tb_bmp_decode;

    localparam integer FW = 1280;
    localparam integer FH = 720;

    reg clk = 1'b0;
    always #6.6667 clk = ~clk;      // 75MHz

    reg rst = 1'b1;
    initial #100 rst = 1'b0;

    reg  [7:0] s_data  = 8'd0;
    reg        s_valid = 1'b0;

    wire        o_we;
    wire [11:0] o_x, o_y;
    wire [15:0] o_rgb565;
    wire        done;
    wire [15:0] img_w, img_h;
    wire        hdr_ok;

    bmp_decode #(.FB_WIDTH(FW), .FB_HEIGHT(FH)) dut (
        .clk(clk), .rst(rst),
        .s_data(s_data), .s_valid(s_valid), .s_ready(),
        .o_we(o_we), .o_x(o_x), .o_y(o_y), .o_rgb565(o_rgb565),
        .o_frame_done(done), .o_img_w(img_w), .o_img_h(img_h), .o_hdr_ok(hdr_ok)
    );

    // ------------------------------------------------------------------
    // 帧缓存（只用于仿真比对）
    // ------------------------------------------------------------------
    reg [15:0] fb [0:FW*FH-1];

    integer pixcnt = 0;
    always @(posedge clk)
        if (o_we) begin
            fb[o_y * FW + o_x] <= o_rgb565;
            pixcnt <= pixcnt + 1;
        end

    // ------------------------------------------------------------------
    // 读文件并按字节喂入
    // ------------------------------------------------------------------
    reg  [7:0] mem [0:1200000];
    integer    nbytes;
    integer    fd;
    integer    i;

    task dump_ppm;
        integer f, k;
        reg [7:0] r, g, b;
        begin
            f = $fopen("bmp_out.ppm", "wb");
            $fwrite(f, "P6\n%0d %0d\n255\n", FW, FH);
            for (k = 0; k < FW*FH; k = k + 1) begin
                r = {fb[k][15:11], 3'b000};
                g = {fb[k][10:5],  2'b00};
                b = {fb[k][4:0],   3'b000};
                $fwrite(f, "%c%c%c", r, g, b);
            end
            $fclose(f);
            $display("[dump] bmp_out.ppm  size=%0dx%0d  img=%0dx%0d hdr_ok=%b",
                     FW, FH, img_w, img_h, hdr_ok);
        end
    endtask

    initial begin
        fd = $fopen("img_test.bmp", "rb");
        if (fd == 0) begin
            $display("ERROR: cannot open img_test.bmp");
            $finish;
        end
        nbytes = $fread(mem, fd);
        $fclose(fd);
        $display("[tb] file bytes = %0d", nbytes);

        wait (rst == 1'b0);
        repeat (5) @(posedge clk);

        // 逐字节喂入（1 字节 / 2 拍）
        for (i = 0; i < nbytes; i = i + 1) begin
            @(negedge clk);
            s_data  = mem[i];
            s_valid = 1'b1;
            @(negedge clk);
            s_valid = 1'b0;
        end

        // 等最后一像素落盘
        repeat (20) @(posedge clk);
        $display("[tb] state=%0d row=%0d col=%0d bcnt=%0d pixcnt=%0d done=%b",
                 dut.state, dut.row, dut.col, dut.bcnt, pixcnt, done);
        dump_ppm;
        $finish;
    end

    // 打印完成事件
    always @(posedge clk)
        if (done)
            $display("[tb] o_frame_done @ %0t  img=%0dx%0d", $time, img_w, img_h);

endmodule
