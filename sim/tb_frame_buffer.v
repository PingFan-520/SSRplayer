`timescale 1ns / 1ps
// ============================================================================
//  tb_frame_buffer.v —— 帧缓存读写闭环验证
//
//  1) 往 1280x720 画布中心 640x480 写一个渐变+棋盘图案
//  2) 等一帧，从读侧按 720p 时序输出并抓图
//  3) 导出 fb_out.ppm，Python 端按同一公式重算期望值逐像素比对
// ============================================================================
module tb_frame_buffer;

    localparam integer FW = 1280;
    localparam integer FH = 720;

    reg pix_clk = 1'b0;
    always #6.6667 pix_clk = ~pix_clk;      // 75MHz

    reg mem_clk = 1'b0;
    always #5.0 mem_clk = ~mem_clk;         // 100MHz

    reg rst = 1'b1;
    initial begin #300; rst = 1'b0; end

    // ---------------- 720p 时序 ----------------
    wire hs, vs, de;
    wire [11:0] hcnt, vcnt;

    color_bar_hd u_bar (
        .clk(pix_clk), .rst(rst),
        .hs(hs), .vs(vs), .de(de),
        .rgb_r(), .rgb_g(), .rgb_b(),
        .o_hcnt(hcnt), .o_vcnt(vcnt)
    );

    localparam integer HSTART = 260;
    localparam integer VSTART = 25;
    wire [11:0] act_x = hcnt - HSTART[11:0];
    wire [11:0] act_y = vcnt - VSTART[11:0];

    // ---------------- SDRAM 行为模型 ----------------
    wire [20:0] wr_addr, rd_addr;
    wire [31:0] wr_din, rd_dout;
    wire        wr_en, rd_en, rd_valid, init_done, ref_vld, busy;
    wire [15:0] violation;

    sdram_app_model u_sdr (
        .clk(mem_clk), .rst(rst),
        .wr_addr(wr_addr), .wr_din(wr_din), .wr_en(wr_en),
        .rd_addr(rd_addr), .rd_en(rd_en),
        .rd_dout(rd_dout), .rd_valid(rd_valid),
        .ref_vld(ref_vld), .busy(busy),
        .init_done(init_done), .violation(violation)
    );

    reg        wr_pix_en  = 1'b0;
    reg [11:0] wr_pix_x   = 12'd0;
    reg [11:0] wr_pix_y   = 12'd0;
    reg [15:0] wr_pix_rgb = 16'd0;

    // ---------------- 帧缓存 ----------------
    wire [15:0] fb_rgb;
    wire        wr_ready;
    wire        fb_de;

    frame_buffer #(.FB_W(FW), .FB_H(FH)) u_fb (
        .app_wr_addr(wr_addr), .app_wr_din(wr_din), .app_wr_en(wr_en),
        .app_rd_addr(rd_addr), .app_rd_en(rd_en),
        .app_rd_valid(rd_valid), .app_rd_dout(rd_dout),
        .app_init_done(init_done),
        .app_ref_vld(ref_vld), .app_busy(busy),
        .clk_mem(mem_clk), .rst_mem(rst),
        .pix_clk(pix_clk), .pix_rst(rst),
        .wr_en(wr_pix_en), .wr_x(wr_pix_x), .wr_y(wr_pix_y), .wr_rgb(wr_pix_rgb),
        .wr_buf(1'b0), .wr_ready(wr_ready),
        .vs(vs), .de(de), .x(act_x), .y(act_y),
        .rd_buf(1'b0),
        .rgb_out(fb_rgb), .de_out(fb_de)
    );

    // ---------------- 写图案 ----------------
    localparam integer X0 = 320;
    localparam integer Y0 = 120;
    localparam integer IW = 640;
    localparam integer IH = 480;

    integer wx, wy;
    reg     img_done = 1'b0;
    reg [7:0] pr, pg, pb;

    // 与 Python 端一致的图案公式
    task calc_px;
        input integer u;
        input integer v;
        begin
            pr = u[7:0] >> 0;
            pg = v[7:0];
            pb = (((u >> 5) + (v >> 5)) & 1) ? 8'hFF : 8'h00;
        end
    endtask

    initial begin
        wait (rst == 1'b0);
        wait (init_done == 1'b1);
        repeat (10) @(posedge pix_clk);

        for (wy = 0; wy < IH; wy = wy + 1) begin
            for (wx = 0; wx < IW; wx = wx + 1) begin
                @(negedge pix_clk);
                while (!wr_ready) @(negedge pix_clk);   // 写窗口有限，满了就等
                wr_pix_en  = 1'b1;
                wr_pix_x   = X0 + wx;
                wr_pix_y   = Y0 + wy;
                calc_px(wx, wy);
                wr_pix_rgb = {pr[7:3], pg[7:2], pb[7:3]};
                @(negedge pix_clk);
                wr_pix_en  = 1'b0;
            end
        end
        img_done = 1'b1;
        repeat (10) @(posedge mem_clk);
        $display("[chk] mem[152*640+160]=%h  mem[120*640+160]=%h",
                 u_sdr.mem[152*640+160], u_sdr.mem[120*640+160]);
        $display("[tb] image written, violations=%0d", violation);
        // 抽查 SDRAM 模型内容：row120 起，x=320 对应 word 160
        repeat (20) @(posedge mem_clk);
        $display("[chk] y120 w160 = %h  (expect 0000)", u_sdr.mem[120*640+160]);
        $display("[chk] y120 w161 = %h  (expect 0840? )", u_sdr.mem[120*640+161]);
        $display("[chk] y152 w160 = %h", u_sdr.mem[152*640+160]);
        $display("[chk] unfilled y0 w0 = %h", u_sdr.mem[0]);
    end

    // ---------------- 抓图 ----------------
    localparam integer DW = FW/2;
    localparam integer DH = FH/2;
    reg [7:0] cap [0:DW*DH*3-1];
    integer   wp = 0;

    always @(posedge pix_clk) begin
        if ((act_x == 12'd0) && (act_y == 12'd0))
            wp <= 0;
        else if (fb_de && (act_x[0] == 1'b0) && (act_y[0] == 1'b0)) begin
            cap[wp]   <= {fb_rgb[15:11], 3'b000};
            cap[wp+1] <= {fb_rgb[10:5],  2'b00};
            cap[wp+2] <= {fb_rgb[4:0],   3'b000};
            wp        <= wp + 3;
        end
    end

    integer f, k;

    initial begin
        wait (rst == 1'b0);
        wait (img_done == 1'b1);          // 等图真正写完
        @(posedge vs);
        @(posedge vs);

        wait ((act_x == 12'd0) && (act_y == 12'd0));
        $display("[dbg] rd_cnt=%0d dout=%h empty=%b pre=%b mem0=%h",
                 u_fb.rd_cnt, u_fb.rf_dout, u_fb.rf_empty, u_fb.pre, u_sdr.mem[0]);
        @(posedge pix_clk); #200;
        f = $fopen("fb_out.ppm", "wb");
        $fwrite(f, "P6\n%0d %0d\n255\n", DW, DH);
        for (k = 0; k < DW*DH*3; k = k + 1) $fwrite(f, "%c", cap[k]);
        $fclose(f);
        $display("[tb] fb_out.ppm dumped, violations=%0d", violation);
        $finish;
    end

endmodule
