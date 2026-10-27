// ============================================================================
//  tb_fat_real.v —— 用**真卡的原始扇区**跑挂载 + 目录扫描
//
//  数据来源：sim/real_card.img（从 SD 卡前 31000 个扇区直接 dump）
//  目的：上板扫不到图片时，在仿真里 1:1 复现"挂载 -> 扫描"这条链路，
//        看到底卡在哪个状态、哪个字段读错了。
//
//  只例化 sd_arb 的 C 口 + fat_mnt + fat_scan，不跑图片/音频。
// ============================================================================
`timescale 1ns / 1ps

module tb_fat_real;

    localparam integer CARD_BYTES = 15_872_000;

    reg clk_sd = 1'b0;
    always #20 clk_sd = ~clk_sd;          // 25MHz

    reg rst = 1'b1;
    reg sd_ok = 1'b0;              // 模拟 init_done：稍晚才放行

    // ------------------------------------------------------------------
    // 假 SD 卡：整卡先读进内存，按扇区供数
    // ------------------------------------------------------------------
    reg [7:0] card [0:CARD_BYTES-1];
    integer   card_n;
    integer   fd;

    initial begin
        fd = $fopen("real_card.img", "rb");
        if (fd == 0) begin
            $display("ERROR: real_card.img not found");
            $finish;
        end
        card_n = $fread(card, fd);
        $fclose(fd);
        $display("[tb] card loaded: %0d bytes (%.1f MB)", card_n, card_n/1048576.0);
    end

    reg        s_start = 1'b0, s_busy = 1'b0, s_val = 1'b0;
    reg [31:0] s_sec   = 32'd0;
    reg [15:0] s_data  = 16'd0;

    wire        arb_start, arb_busy, arb_val;
    wire [31:0] arb_sec;
    wire [15:0] arb_data;

    integer    scnt;
    reg        phase, getaddr;
    reg [4:0]  tail;              // 512 字节之后 busy 还要多保持几拍（真实控制器行为）

    always @(posedge clk_sd) begin
        s_val <= 1'b0;
        if (!rst && arb_start && !s_busy) begin
            s_busy  <= 1'b1;
            scnt    <= 0;
            phase   <= 1'b0;
            getaddr <= 1'b1;
            tail    <= 5'd0;
        end else if (s_busy) begin
            if (getaddr) begin
                if (arb_sec * 512 >= CARD_BYTES) begin
                    $display("[tb] !! read beyond image: sec=%0d", arb_sec);
                    s_busy <= 1'b0;
                end else begin
                    s_sec   <= arb_sec;
                    getaddr <= 1'b0;
                end
            end else if (tail != 5'd0) begin
                // 最后两个字之后的"尾巴"：只有 busy，没有数据
                tail <= tail - 5'd1;
                if (tail == 5'd1) s_busy <= 1'b0;
            end else if (!phase) begin
                phase <= 1'b1;
            end else begin
                s_data <= {card[s_sec*512 + scnt*2], card[s_sec*512 + scnt*2 + 1]};
                s_val  <= 1'b1;
                phase  <= 1'b0;
                if (scnt == 255) tail <= 5'd12;
                else             scnt <= scnt + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 仲裁器：只用 C 口（挂载 / 扫描共用）
    // ------------------------------------------------------------------
    wire        mnt_start, scan_start;
    wire [31:0] mnt_sec, scan_sec;
    wire        c_start, c_busy, c_val;
    wire [31:0] c_sec;
    wire [15:0] c_data;

    wire        creq = mnt_start | scan_start;
    wire [31:0] csec = mnt_start ? mnt_sec : scan_sec;

    sd_arb u_arb (
        .clk(clk_sd), .rst_n(~rst),
        .a_req(1'b0), .a_sec(32'd0),
        .a_busy(), .a_val(), .a_data(), .a_gnt(),
        .b_req(1'b0), .b_sec(32'd0),
        .b_busy(), .b_val(), .b_data(), .b_gnt(),
        .c_req(creq), .c_sec(csec),
        .c_busy(c_busy), .c_val(c_val), .c_data(c_data), .c_gnt(),
        .s_start(arb_start), .s_sec(arb_sec),
        .s_busy(arb_busy), .s_val(arb_val), .s_data(arb_data),
        .sd_init_done(sd_ok)
    );

    assign arb_busy = s_busy;
    assign arb_val  = s_val;
    assign arb_data = s_data;

    // ------------------------------------------------------------------
    // 挂载
    // ------------------------------------------------------------------
    wire        mnt_done, mnt_ok;
    wire [2:0]  mnt_st;
    wire [31:0] part_lba, fat_lba, data_lba, root_clus;
    wire [3:0]  spc_log2;
    wire [7:0]  mnt_err;

    fat_mnt u_mnt (
        .clk(clk_sd), .rst(rst),
        .rd_start_en(mnt_start), .rd_sec_addr(mnt_sec),
        .rd_busy(c_busy), .rd_val_en(c_val), .rd_val_data(c_data),
        .sd_init_done(sd_ok),
        .mnt_ok(mnt_ok), .part_lba(part_lba), .fat_lba(fat_lba),
        .data_lba(data_lba), .spc_log2(spc_log2), .root_clus(root_clus),
        .mnt_done(mnt_done), .mnt_err(mnt_err), .dbg_st(mnt_st)
    );

    // ------------------------------------------------------------------
    // 扫描
    // ------------------------------------------------------------------
    wire        scan_done;
    wire [7:0]  img_total, scan_err;
    wire [3:0]  mus_total;
    wire        tw_en;
    wire [9:0]  tw_addr;
    wire [7:0]  tw_data;

    fat_scan #(.IMG_MAX(56), .MUS_MAX(6)) u_scan (
        .clk(clk_sd), .rst(rst),
        .rd_start_en(scan_start), .rd_sec_addr(scan_sec),
        .rd_busy(c_busy), .rd_val_en(c_val), .rd_val_data(c_data),
        .sd_init_done(sd_ok),
        .mnt_ok(mnt_ok), .mnt_done(mnt_done),
        .fat_lba(fat_lba), .data_lba(data_lba), .spc_log2(spc_log2),
        .root_clus(root_clus),
        .tw_en(tw_en), .tw_addr(tw_addr), .tw_data(tw_data),
        .img_total(img_total), .mus_total(mus_total),
        .scan_done(scan_done), .scan_err(scan_err),
        .dbg_st()
    );

    // ------------------------------------------------------------------
    // 观测
    // ------------------------------------------------------------------
    reg [2:0] st_d;
    integer   cyc = 0, dbg = 0;

    always @(posedge clk_sd) begin
        cyc = cyc + 1;
        if (mnt_done)
            $display("[mnt] done ok=%b part=%0d fat=%0d data=%0d spc_log2=%0d root=%0d err=%0d",
                     mnt_ok, part_lba, fat_lba, data_lba, spc_log2, root_clus, mnt_err);
        if (scan_done)
            $display("[scan] done img=%0d mus=%0d err=%0d", img_total, mus_total, scan_err);
        if (u_mnt.st !== st_d) begin
            st_d <= u_mnt.st;
            $display("[mnt-st] t=%0d st=%0d bcnt=%0d bsy=%b ptype=%h part=%0d sig0=%h",
                     cyc, u_mnt.st, u_mnt.bcnt, u_mnt.bsy, u_mnt.ptype, part_lba, u_mnt.sig0);
        end
        if (dbg < 40 && cyc % 20000 == 0) begin
            dbg = dbg + 1;
            $display("[watch] cyc=%0d mnt_st=%0d scan_st=%0d img=%0d mus=%0d bcnt=%0d sec_in=%0d clus=%0d",
                     cyc, u_mnt.st, u_scan.st, img_total, mus_total,
                     u_scan.bcnt, u_scan.sec_in, u_scan.cur_clus);
        end
        if (cyc == 3_000_000) begin
            $display("[timeout] mnt_st=%0d scan_st=%0d img=%0d mus=%0d", u_mnt.st, u_scan.st, img_total, mus_total);
            $finish;
        end
    end

    initial begin
        repeat (10) @(posedge clk_sd);
        rst <= 1'b0;
        repeat (2000) @(posedge clk_sd);
        sd_ok <= 1'b1;                 // 晚 80us 才放行，验证门控
        $display("[tb] sd_ok released");
        @(posedge scan_done);
        repeat (100) @(posedge clk_sd);
        $display("RESULT: img=%0d mus=%0d scan_err=%0d mnt_err=%0d", img_total, mus_total, scan_err, mnt_err);
        $finish;
    end

endmodule
