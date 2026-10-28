// ============================================================================
//  sd_bmp_reader.v —— FAT32 图片读取器 + 挂载 + 目录扫描 + 文件表
//
//  ★ 2026-10-27 大改：不再用自制裸扇区镜像，改成**真 FAT32**
//
//  卡上就是普通 FAT32（Windows 格式化即可），根目录放 *.BMP / *.WAV，
//  插上就能用；图片数量由目录里实际的文件数决定，不再是写死的 IMG_NUM。
//
//  本文件包含 4 个模块（TD 命令行不会重新读取 .al 里新增的文件条目，
//  所以新模块必须并进已有文件）：
//     fat_tbl    —— 1KB 文件表（64 条 x 16B：起始簇 4B + 大小 4B + 名字 8B）
//     fat_mnt    —— 读 MBR/BPB，算出 FAT/数据区起始、簇大小、根目录簇
//     fat_scan   —— 遍历根目录，把 BMP/WAV 记进文件表
//     sd_bmp_reader —— 按簇链读一个 BMP 文件，输出字节流给 bmp_decode
//
//  文件表记录布局（16 字节，小端）：
//     [0..3]  起始簇
//     [4..7]  文件字节数
//     [8..15] 8.3 短名（不足补 0x00，显示时遇到 0 截断）
//    记录 0..55 = 图片，56..61 = 音乐
//
//  簇链读取：每个簇读 spc 个扇区，簇末尾再读 1 个 FAT 扇区拿下一簇。
//  一个簇 4KB 起步，FAT 开销 < 2%。
// ============================================================================
`timescale 1ns / 1ps

// ============================================================================
//  文件表：64 条 x 16 字节 = 1KB（1 块 M9K）
//  写口给扫描器；读口给图片/音乐两个使用者（音乐优先），16 拍读出一条。
// ============================================================================
module fat_tbl (
    input  wire         clk,
    input  wire         rst,

    // ---- 写（扫描器）----
    input  wire         wr_en,
    input  wire [9:0]   wr_addr,
    input  wire [7:0]   wr_data,

    // ---- 读：使用者 I（图片）----
    input  wire         i_req,        // 电平，保持到 i_done
    input  wire [5:0]   i_rec,
    output reg          i_done,       // 单拍
    output reg  [127:0] i_data,

    // ---- 读：使用者 M（音乐）----
    input  wire         m_req,
    input  wire [5:0]   m_rec,
    output reg          m_done,
    output reg  [127:0] m_data
);

    reg [7:0] mem [0:1023];

    // 读端口（1 拍延迟）
    reg [9:0] raddr;
    reg [7:0] rq;

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    // 请求：上升沿登记（客户端会把 req 保持到 done），被服务时清掉
    reg i_req_d, m_req_d;
    reg i_pend, m_pend;

    always @(posedge clk) begin
        i_req_d <= i_req;
        m_req_d <= m_req;
    end

    wire i_rise = i_req & ~i_req_d;
    wire m_rise = m_req & ~m_req_d;

    reg        busy;
    reg        who_m;         // 1 = 音乐
    reg [5:0]  rec;
    reg [4:0]  k;             // 0..15
    reg  [1:0] ph;            // 0=发地址 1=等 BRAM 输出 2=收数据
    reg [127:0] sh;

    wire start_m = ~busy & m_pend;
    wire start_i = ~busy & ~m_pend & i_pend;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            i_pend <= 1'b0;
            m_pend <= 1'b0;
        end else begin
            if (i_rise) i_pend <= 1'b1;
            if (m_rise) m_pend <= 1'b1;
            if (start_m) m_pend <= 1'b0;
            if (start_i) i_pend <= 1'b0;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy   <= 1'b0;
            who_m  <= 1'b0;
            rec    <= 6'd0;
            k      <= 5'd0;
            ph     <= 2'd0;
            sh     <= 128'd0;
            raddr  <= 10'd0;
            rq     <= 8'd0;
            i_done <= 1'b0;
            m_done <= 1'b0;
            i_data <= 128'd0;
            m_data <= 128'd0;
        end else begin
            i_done <= 1'b0;
            m_done <= 1'b0;

            if (start_m) begin
                busy  <= 1'b1;
                who_m <= 1'b1;
                rec   <= m_rec;
                k     <= 5'd0;
                ph    <= 2'd0;
            end else if (start_i) begin
                busy  <= 1'b1;
                who_m <= 1'b0;
                rec   <= i_rec;
                k     <= 5'd0;
                ph    <= 2'd0;
            end else if (busy) begin
                if (ph == 2'd0) begin
                    raddr <= {rec, 4'd0} + {5'd0, k[3:0]};
                    ph    <= 2'd1;
                end else if (ph == 2'd1) begin
                    rq <= mem[raddr];
                    ph <= 2'd2;
                end else begin
                    // 右移拼接：第 k 个字节最后落在 [8k +: 8]
                    sh <= {rq, sh[127:8]};
                    if (k == 5'd15) begin
                        busy <= 1'b0;
                        ph   <= 2'd0;
                        if (who_m) begin
                            m_data <= {rq, sh[127:8]};
                            m_done <= 1'b1;
                        end else begin
                            i_data <= {rq, sh[127:8]};
                            i_done <= 1'b1;
                        end
                    end else begin
                        k  <= k + 5'd1;
                        ph <= 2'd0;
                    end
                end
            end
        end
    end

endmodule


// ============================================================================
//  挂载：LBA0 -> 分区 -> BPB
// ============================================================================
module fat_mnt (
    input  wire        clk,
    input  wire        rst,

    output reg         rd_start_en,
    output reg  [31:0] rd_sec_addr,
    input  wire        rd_busy,
    input  wire        rd_val_en,
    input  wire [15:0] rd_val_data,
    input  wire        sd_init_done,

    output reg         mnt_ok,
    output reg  [31:0] part_lba,
    output reg  [31:0] fat_lba,
    output reg  [31:0] data_lba,
    output reg  [3:0]  spc_log2,
    output reg  [31:0] root_clus,
    output reg         mnt_done,
    output reg  [7:0]  mnt_err,
    output wire [2:0]  dbg_st          // 当前状态（数码管诊断）
);
    reg mounted;

    localparam [2:0] S_IDLE = 3'd0,
                     S_M0   = 3'd1,   // 读 MBR，等数据
                     S_M1   = 3'd2,   // 收 512 字节
                     S_B0   = 3'd3,   // 读 BPB
                     S_B1   = 3'd4,
                     S_DONE = 3'd5;

    reg [2:0]  st;
    assign dbg_st = st;
    reg        bsy;                   // 已看到本次 busy
    reg [9:0]  bcnt;                  // 扇区内字节号
    reg        pend_v;
    reg [7:0]  pend;

    reg [7:0]  sig0, sig1;
    reg [7:0]  ptype;
    reg [31:0] plba;
    reg [15:0] bps;
    reg [7:0]  spc, nfat;
    reg [15:0] rsvd;
    reg [31:0] fatsz, root;

    wire        byte_en = rd_val_en | pend_v;
    wire [7:0]  byte_d  = rd_val_en ? rd_val_data[15:8] : pend;

    reg [2:0] spc_l2;
    always @(*) begin
        case (spc)
            8'd1:   spc_l2 = 3'd0;
            8'd2:   spc_l2 = 3'd1;
            8'd4:   spc_l2 = 3'd2;
            8'd8:   spc_l2 = 3'd3;
            8'd16:  spc_l2 = 3'd4;
            8'd32:  spc_l2 = 3'd5;
            8'd64:  spc_l2 = 3'd6;
            8'd128: spc_l2 = 3'd7;
            default: spc_l2 = 3'd3;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= S_IDLE;
            rd_start_en <= 1'b0;
            rd_sec_addr <= 32'd0;
            bsy         <= 1'b0;
            bcnt        <= 10'd0;
            pend_v      <= 1'b0;
            pend        <= 8'd0;
            sig0        <= 8'd0;
            sig1        <= 8'd0;
            ptype       <= 8'd0;
            plba        <= 32'd0;
            bps         <= 16'd0;
            spc         <= 8'd0;
            nfat        <= 8'd0;
            rsvd        <= 16'd0;
            fatsz       <= 32'd0;
            root        <= 32'd0;
            mnt_ok      <= 1'b0;
            part_lba    <= 32'd0;
            fat_lba     <= 32'd0;
            data_lba    <= 32'd0;
            spc_log2    <= 4'd3;
            root_clus   <= 32'd0;
            mnt_done    <= 1'b0;
            mnt_err     <= 8'd0;
            mounted     <= 1'b0;
        end else begin
            mnt_done <= 1'b0;

            // 16bit -> 2 字节
            if (rd_val_en) begin
                pend   <= rd_val_data[7:0];
                pend_v <= 1'b1;
            end else if (pend_v) begin
                pend_v <= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (sd_init_done && !mounted && !rd_busy) begin
                        rd_sec_addr <= 32'd0;
                        rd_start_en <= 1'b1;
                        bcnt        <= 10'd0;
                        bsy         <= 1'b0;
                        st          <= S_M0;
                    end
                end

                S_M0: begin
                    if (rd_busy) begin
                        rd_start_en <= 1'b0;
                        bsy         <= 1'b1;
                        st          <= S_M1;
                    end
                end

                S_M1: begin
                    if (bsy && byte_en) begin
                        case (bcnt)
                            10'd450: ptype      <= byte_d;         // 分区类型
                            10'd454: plba[7:0]  <= byte_d;
                            10'd455: plba[15:8] <= byte_d;
                            10'd456: plba[23:16]<= byte_d;
                            10'd457: plba[31:24]<= byte_d;
                            10'd510: sig0       <= byte_d;
                            10'd511: sig1       <= byte_d;
                            default: ;
                        endcase
                        bcnt <= bcnt + 10'd1;
                        if (bcnt == 10'd511) begin
                            // 0x55AA + 合法分区类型才认分区表，否则按"超级软盘"处理。
                            // 注意：第 511 字节就是 0xAA，本拍 sig1 还没落盘，直接看 byte_d。
                            if ((sig0 == 8'h55) && (byte_d == 8'hAA) &&
                                ((ptype == 8'h0B) || (ptype == 8'h0C) ||
                                 (ptype == 8'h0E) || (ptype == 8'h06) ||
                                 (ptype == 8'h04)))
                                part_lba <= plba;
                            else
                                part_lba <= 32'd0;
                            bcnt <= 10'd0;
                            bsy  <= 1'b0;
                            st   <= S_B0;
                        end
                    end
                end

                S_B0: begin
                    if (!rd_busy) begin
                        rd_sec_addr <= part_lba;
                        rd_start_en <= 1'b1;
                        st          <= S_B1;
                    end
                end

                S_B1: begin
                    if (rd_busy) begin
                        bsy         <= 1'b1;
                        rd_start_en <= 1'b0;      // ★ 必须立刻撤，否则仲裁器会重复授权
                    end
                    if (bsy && byte_en) begin
                        case (bcnt)
                            10'd11: bps[7:0]   <= byte_d;
                            10'd12: bps[15:8]  <= byte_d;
                            10'd13: spc        <= byte_d;
                            10'd14: rsvd[7:0]  <= byte_d;
                            10'd15: rsvd[15:8] <= byte_d;
                            10'd16: nfat       <= byte_d;
                            10'd36: fatsz[7:0]   <= byte_d;
                            10'd37: fatsz[15:8]  <= byte_d;
                            10'd38: fatsz[23:16] <= byte_d;
                            10'd39: fatsz[31:24] <= byte_d;
                            10'd44: root[7:0]   <= byte_d;
                            10'd45: root[15:8]  <= byte_d;
                            10'd46: root[23:16] <= byte_d;
                            10'd47: root[31:24] <= byte_d;
                            default: ;
                        endcase
                        bcnt <= bcnt + 10'd1;
                        if (bcnt == 10'd511) begin
                            rd_start_en <= 1'b0;
                            st <= S_DONE;
                        end
                    end
                end

                S_DONE: begin
                    fat_lba   <= part_lba + {16'd0, rsvd};
                    data_lba  <= part_lba + {16'd0, rsvd} +
                                 ((nfat == 8'd2) ? {fatsz[30:0], 1'b0} : fatsz);
                    spc_log2  <= {1'b0, spc_l2};
                    root_clus <= root;
                    // 512B/扇区、簇大小 1..128 且为 2 的幂、FAT 非空、根簇合法
                    mnt_ok    <= (bps == 16'd512) && (spc != 8'd0) &&
                                 ((spc & (spc - 8'd1)) == 8'd0) && (spc <= 8'd128) &&
                                 (fatsz != 32'd0) && (root >= 32'd2) && (root < 32'h0FFFFFF0);
                    mnt_err   <= ((bps == 16'd512) && (fatsz != 32'd0) &&
                                  (root >= 32'd2)) ? 8'd0 : 8'd1;
                    mnt_done  <= 1'b1;
                    mounted   <= 1'b1;
                    st        <= S_IDLE;
                    bsy       <= 1'b0;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule


// ============================================================================
//  目录扫描：根目录簇链 -> 文件表
// ============================================================================
module fat_scan #(
    parameter integer IMG_MAX = 56,       // 记录 0..55
    parameter integer MUS_MAX = 6         // 记录 56..61
)(
    input  wire        clk,
    input  wire        rst,

    output reg         rd_start_en,
    output reg  [31:0] rd_sec_addr,
    input  wire        rd_busy,
    input  wire        rd_val_en,
    input  wire [15:0] rd_val_data,
    input  wire        sd_init_done,

    input  wire        mnt_ok,
    input  wire        mnt_done,
    input  wire [31:0] fat_lba,
    input  wire [31:0] data_lba,
    input  wire [3:0]  spc_log2,
    input  wire [31:0] root_clus,

    output reg         tw_en,
    output reg  [9:0]  tw_addr,
    output reg  [7:0]  tw_data,

    output reg  [7:0]  img_total,
    output reg  [3:0]  mus_total,
    output reg         scan_done,
    output reg  [7:0]  scan_err,
    output wire [3:0]  dbg_st          // 当前状态（数码管诊断）
);

    localparam [7:0] IMGMAX = IMG_MAX;
    localparam [3:0] MUSMAX = MUS_MAX;

    localparam [3:0] S_WAIT = 4'd0,
                     S_CMD  = 4'd1,
                     S_WT   = 4'd2,
                     S_RCV  = 4'd3,
                     S_GAP  = 4'd4,
                     S_F0   = 4'd5,    // 读 FAT 扇区
                     S_F1   = 4'd6,
                     S_F2   = 4'd7,
                     S_END  = 4'd8;

    reg [3:0]  st;
    assign dbg_st = st;

    // 扇区级超时 + 重试（21ms 量级，远大于任何正常等待）。原来 S_WT 等 rd_busy、S_RCV 等 256 个字都没有退路：
    // 只要有一次请求没被受理、或者 SPI 丢了字节，就会永远停在这里，
    // 上层只能等 7 秒看门狗（上板现象：进度 0→99 反复重来、一次切图要 30 秒）。
    reg [15:0] wto;             // 等待计数（2.6ms @25MHz）
    reg [1:0]  retry;           // 本扇区重试次数
    reg        bsy;
    reg [9:0]  bcnt;
    reg        pend_v;
    reg [7:0]  pend;

    reg [31:0] cur_clus;
    reg [7:0]  sec_in;                // 簇内第几个扇区
    reg [31:0] foff;                  // FAT 扇区内字节偏移
    reg [31:0] nxt_clus;
    reg        dir_end;
    reg        ev;                    // 一项刚收完，下一拍评估
    reg        fav;                   // FAT 扇区刚收完，下一拍评估

    // 32 字节目录项组装
    reg [7:0]  nm  [0:10];
    reg [7:0]  attr;
    reg [15:0] cl_lo, cl_hi;
    reg [31:0] fsz;
    reg [7:0]  eoff;                  // 项内字节号 0..31

    // 写缓冲
    reg        wb_busy;
    reg [127:0] wb;
    reg [5:0]  wb_rec;
    reg [4:0]  wb_k;

    integer j;

    wire        byte_en = rd_val_en | pend_v;
    wire [7:0]  byte_d  = rd_val_en ? rd_val_data[15:8] : pend;
    wire [9:0]  next_bc = bcnt + 10'd1;

    // 当前项是不是目标文件
    wire [7:0]  e0  = nm[0];
    wire        is_lfn = (attr == 8'h0F);
    wire        is_dir = (attr[4]) || (attr[3]);      // 目录 / 卷标
    wire [7:0]  ex0 = nm[8]  | 8'h20;                 // 转小写
    wire [7:0]  ex1 = nm[9]  | 8'h20;
    wire [7:0]  ex2 = nm[10] | 8'h20;
    wire        is_bmp = (ex0 == "b") && (ex1 == "m") && (ex2 == "p");
    wire        is_wav = (ex0 == "w") && (ex1 == "a") && (ex2 == "v");

    wire        fit_img = is_bmp && (img_total < IMGMAX);
    wire        fit_mus = is_wav && (mus_total < MUSMAX);

    // 名字 8 字节，空格 -> 0（显示时遇到 0 截断）
    wire [63:0] nm64 = { (nm[7] == 8'h20) ? 8'h00 : nm[7],
                         (nm[6] == 8'h20) ? 8'h00 : nm[6],
                         (nm[5] == 8'h20) ? 8'h00 : nm[5],
                         (nm[4] == 8'h20) ? 8'h00 : nm[4],
                         (nm[3] == 8'h20) ? 8'h00 : nm[3],
                         (nm[2] == 8'h20) ? 8'h00 : nm[2],
                         (nm[1] == 8'h20) ? 8'h00 : nm[1],
                         (nm[0] == 8'h20) ? 8'h00 : nm[0] };
    wire [31:0] ent_clus = {cl_hi, cl_lo};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= S_WAIT;
            rd_start_en <= 1'b0;
            rd_sec_addr <= 32'd0;
            bsy         <= 1'b0;
            bcnt        <= 10'd0;
            pend_v      <= 1'b0;
            pend        <= 8'd0;
            cur_clus    <= 32'd0;
            sec_in      <= 8'd0;
            foff        <= 32'd0;
            nxt_clus    <= 32'd0;
            dir_end     <= 1'b0;
            ev          <= 1'b0;
            fav         <= 1'b0;
            attr        <= 8'd0;
            cl_lo       <= 16'd0;
            cl_hi       <= 16'd0;
            fsz         <= 32'd0;
            eoff        <= 8'd0;
            tw_en       <= 1'b0;
            tw_addr     <= 10'd0;
            tw_data     <= 8'd0;
            img_total   <= 8'd0;
            mus_total   <= 4'd0;
            scan_done   <= 1'b0;
            scan_err    <= 8'd0;
            wb_busy     <= 1'b0;
            wb          <= 128'd0;
            wb_rec      <= 6'd0;
            wb_k        <= 5'd0;
            for (j = 0; j < 11; j = j + 1) nm[j] <= 8'd0;
        end else begin
            tw_en <= 1'b0;

            if (rd_val_en) begin
                pend   <= rd_val_data[7:0];
                pend_v <= 1'b1;
            end else if (pend_v) begin
                pend_v <= 1'b0;
            end

            // ---------------- 表写后台 ----------------
            if (wb_busy) begin
                tw_en   <= 1'b1;
                tw_addr <= {wb_rec, 4'd0} + {5'd0, wb_k};
                tw_data <= wb[{wb_k, 3'b000} +: 8];
                wb_k    <= wb_k + 5'd1;
                if (wb_k == 5'd15) wb_busy <= 1'b0;
            end

            case (st)
                S_WAIT: begin
                    if (mnt_done) begin
                        if (mnt_ok) begin
                            cur_clus <= root_clus;
                            sec_in   <= 8'd0;
                            bcnt     <= 10'd0;
                            bsy      <= 1'b0;
                            st       <= S_CMD;
                        end else begin
                            scan_err  <= 8'd1;
                            scan_done <= 1'b1;
                            st        <= S_END;
                        end
                    end
                end

                S_CMD: begin
                    // ★ 必须等上一次传输的 busy 真正落下再发请求。
                    //   挂载刚结束时 s_busy 还有十几拍尾巴，owner 仍是 C 口，
                    //   S_WT 会把这个尾巴当成"自己的传输已经开始"，撤掉请求，
                    //   然后就永远等不到 512 字节（上板现象：scan 卡在 S_RCV）。
                    if (!rd_busy) begin
                        rd_sec_addr <= data_lba + ((cur_clus - 32'd2) << spc_log2) + {24'd0, sec_in};
                        rd_start_en <= 1'b1;
                        st          <= S_WT;
                    end
                end

                S_WT: begin
                    if (rd_busy) begin
                        rd_start_en <= 1'b0;
                        bsy         <= 1'b1;
                        st          <= S_RCV;
                    end
                end

                S_RCV: begin
                    // 上一拍刚收完一项：此时名字/簇/大小都到齐了
                    if (ev) begin
                        ev <= 1'b0;
                        if (!is_lfn && !is_dir && (e0 != 8'hE5) && (e0 != 8'h00) &&
                            (fit_img || fit_mus) && !wb_busy) begin
                            wb      <= {nm64, fsz, ent_clus};
                            wb_rec  <= fit_img ? img_total[5:0] : (6'd56 + mus_total);
                            wb_busy <= 1'b1;
                            wb_k    <= 5'd0;
                            if (fit_img) img_total <= img_total + 8'd1;
                            else         mus_total <= mus_total + 4'd1;
                        end
                    end

                    if (bsy && byte_en) begin
                        // 32 字节一项：按项内偏移抓字段
                        if (bcnt[4:0] <= 5'd10) nm[bcnt[4:0]] <= byte_d;
                        if (bcnt[4:0] == 5'd11) attr  <= byte_d;
                        if (bcnt[4:0] == 5'd20) cl_hi[7:0]  <= byte_d;
                        if (bcnt[4:0] == 5'd21) cl_hi[15:8] <= byte_d;
                        if (bcnt[4:0] == 5'd26) cl_lo[7:0]  <= byte_d;
                        if (bcnt[4:0] == 5'd27) cl_lo[15:8] <= byte_d;
                        if (bcnt[4:0] == 5'd28) fsz[7:0]   <= byte_d;
                        if (bcnt[4:0] == 5'd29) fsz[15:8]  <= byte_d;
                        if (bcnt[4:0] == 5'd30) fsz[23:16] <= byte_d;
                        if (bcnt[4:0] == 5'd31) fsz[31:24] <= byte_d;

                        // 目录结束标记：0x00
                        if ((bcnt[4:0] == 5'd0) && (byte_d == 8'h00)) dir_end <= 1'b1;

                        bcnt <= next_bc;

                        if (bcnt[4:0] == 5'd31) ev <= 1'b1;

                        if (bcnt == 10'd511) begin
                            bcnt <= 10'd0;
                            bsy  <= 1'b0;
                            st   <= S_GAP;
                        end
                    end
                end

                S_GAP: begin
                    if (!rd_busy) begin
                        if (dir_end) begin
                            scan_done <= 1'b1;
                            scan_err  <= (img_total == 8'd0) ? 8'd3 : 8'd0;
                            st        <= S_END;
                        end else if (sec_in + 8'd1 < (8'd1 << spc_log2)) begin
                            sec_in <= sec_in + 8'd1;
                            bsy    <= 1'b0;
                            st     <= S_CMD;
                        end else begin
                            // 簇末：读 FAT 拿下一簇
                            foff <= {24'd0, cur_clus[6:0]} << 2;
                            st   <= S_F0;
                        end
                    end
                end

                S_F0: begin
                    rd_sec_addr <= fat_lba + {23'd0, cur_clus[31:7]};
                    rd_start_en <= 1'b1;
                    bcnt        <= 10'd0;
                    bsy         <= 1'b0;
                    nxt_clus    <= 32'hFFFFFFFF;
                    st          <= S_F1;
                end

                S_F1: begin
                    if (rd_busy) begin
                        rd_start_en <= 1'b0;
                        bsy         <= 1'b1;
                        st          <= S_F2;
                    end
                end

                S_F2: begin
                    if (fav) begin
                        fav <= 1'b0;
                        if ((nxt_clus >= 32'h0FFFFFF8) || (nxt_clus < 32'd2)) begin
                            dir_end <= 1'b1;           // 目录链断了就当扫完
                            st      <= S_GAP;
                        end else begin
                            cur_clus <= nxt_clus;
                            sec_in   <= 8'd0;
                            st       <= S_CMD;
                        end
                    end
                    if (bsy && byte_en) begin
                        if (bcnt == foff[9:0])         nxt_clus[7:0]   <= byte_d;
                        if (bcnt == foff[9:0] + 10'd1) nxt_clus[15:8]  <= byte_d;
                        if (bcnt == foff[9:0] + 10'd2) nxt_clus[23:16] <= byte_d;
                        if (bcnt == foff[9:0] + 10'd3) nxt_clus[31:24] <= byte_d;
                        bcnt <= next_bc;
                        if (bcnt == 10'd511) begin
                            bcnt <= 10'd0;
                            bsy  <= 1'b0;
                            fav  <= 1'b1;
                        end
                    end
                end

                S_END: begin
                    if (!scan_done) scan_done <= 1'b1;
                end

                default: st <= S_WAIT;
            endcase
        end
    end

endmodule


// ============================================================================
//  图片读取器：按簇链读一个 BMP，输出字节流
// ============================================================================
module sd_bmp_reader (
    input  wire        clk,            // SD 时钟域（25MHz）
    input  wire        rst,

    // ---- 与 sd_ctrl_top 的读接口 ----
    output reg         rd_start_en,
    output reg  [31:0] rd_sec_addr,
    input  wire        rd_busy,
    input  wire        rd_val_en,
    input  wire [15:0] rd_val_data,
    input  wire        sd_init_done,

    // ---- FAT 布局（来自 fat_mnt）----
    input  wire [31:0] fat_lba,
    input  wire [31:0] data_lba,
    input  wire [3:0]  spc_log2,

    // ---- 文件表 ----
    output reg         tbl_req,
    output reg  [5:0]  tbl_rec,
    input  wire        tbl_done,
    input  wire [127:0] tbl_data,

    // ---- 控制（电平）----
    input  wire        enable,
    input  wire [7:0]  img_idx,
    input  wire [8:0]  fifo_used,
    input  wire        stop,           // 解码器已收够
    output reg         busy,
    output reg         done,
    output reg         err,            // 1 = 本次加载有扇区读失败（重试用尽）
    output reg  [3:0]  err_st,         // 出错时的状态快照（诊断，0 = 本次没出错）

    // ---- 字节流输出 ----
    output reg  [7:0]  byte_data,
    output reg         byte_valid
);

    localparam [3:0] S_IDLE = 4'd0,
                     S_TBL  = 4'd1,
                     S_CMD  = 4'd2,
                     S_WT   = 4'd3,
                     S_RCV  = 4'd4,
                     S_GAP  = 4'd5,
                     S_F0   = 4'd6,
                     S_F1   = 4'd7,
                     S_F2   = 4'd8,
                     S_END  = 4'd9;

    reg [3:0]  st;
    assign dbg_st = st;

    // 扇区级超时 + 重试（21ms 量级，远大于任何正常等待）。原来 S_WT 等 rd_busy、S_RCV 等 256 个字都没有退路：
    // 只要有一次请求没被受理、或者 SPI 丢了字节，就会永远停在这里，
    // 上层只能等 7 秒看门狗（上板现象：进度 0→99 反复重来、一次切图要 30 秒）。
    reg [16:0] wto;             // 等待计数（5.2ms @25MHz，正常等待都在 1ms 内）
    reg [1:0]  retry;           // 本扇区重试次数
    reg        bsy;
    reg [8:0]  word_cnt;
    reg [9:0]  bcnt;
    reg        pend_v;
    reg [7:0]  pend;

    // 错误现场快照：出错那一拍 reader 停在哪个状态，显示在数码管第 2 位。
    //   1=TBL 2=CMD 3=WT 4=RCV 5=GAP 6=F0 7=F1 8=F2（0=本次加载没出错）
    //   st_d = st 打一拍；err 起来那拍 st 已经跳回 S_IDLE 了，所以取 st_d。
    //   （err_st 本身是端口，已在端口表里声明为 reg）
    reg [3:0]  st_d;

    reg [1:0]  pretry;          // FAT 扇区（簇链）重试次数
    reg [31:0] cur_clus;
    reg [7:0]  sec_in;
    reg [31:0] bytes_left;
    reg [31:0] foff;
    reg [31:0] nxt_clus;
    reg        fav;
    reg        started;
    reg        data_sector;   // 1 = 当前这次读是文件数据（字节要送去解码）

    // 跨时钟同步
    reg        en_s1, en_s2;
    reg [7:0]  ix_s1, ix_s2;
    reg        sdi_s1, sdi_s2;
    reg [8:0]  fu_s1, fu_s2;
    reg        sp_s1, sp_s2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            en_s1  <= 1'b0;  en_s2  <= 1'b0;
            ix_s1  <= 8'd0;  ix_s2  <= 8'd0;
            sdi_s1 <= 1'b0;  sdi_s2 <= 1'b0;
            fu_s1  <= 9'd0;  fu_s2  <= 9'd0;
            sp_s1  <= 1'b0;  sp_s2  <= 1'b0;
        end else begin
            en_s1  <= enable;
            en_s2  <= en_s1;
            ix_s1  <= img_idx;
            ix_s2  <= ix_s1;
            sdi_s1 <= sd_init_done;
            sdi_s2 <= sdi_s1;
            fu_s1  <= fifo_used;
            fu_s2  <= fu_s1;
            sp_s1  <= stop;
            sp_s2  <= sp_s1;
        end
    end

    wire        byte_en = rd_val_en | pend_v;
    wire [7:0]  byte_d  = rd_val_en ? rd_val_data[15:8] : pend;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= S_IDLE;
            rd_start_en <= 1'b0;
            rd_sec_addr <= 32'd0;
            bsy         <= 1'b0;
            err         <= 1'b0;
            wto         <= 17'd0;
            retry       <= 2'd0;
            pretry      <= 2'd0;
            word_cnt    <= 9'd0;
            bcnt        <= 10'd0;
            pend_v      <= 1'b0;
            pend        <= 8'd0;
            cur_clus    <= 32'd0;
            sec_in      <= 8'd0;
            bytes_left  <= 32'd0;
            foff        <= 32'd0;
            nxt_clus    <= 32'd0;
            fav         <= 1'b0;
            started     <= 1'b0;
            data_sector <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            byte_data   <= 8'd0;
            byte_valid  <= 1'b0;
            tbl_req     <= 1'b0;
            tbl_rec     <= 6'd0;
            st_d        <= S_IDLE;
            err_st      <= 4'd0;
        end else begin
            byte_valid <= 1'b0;
            st_d       <= st;
            if (err) err_st <= st_d;      // err 起来那拍 st 已跳回 S_IDLE，取打一拍的

            if (!en_s2) begin
                started <= 1'b0;
                done    <= 1'b0;
            end

            // 16bit -> 2 字节（只有文件数据扇区才输出，FAT 扇区的字节必须丢掉）
            if (rd_val_en) begin
                if (data_sector) begin
                    byte_data  <= rd_val_data[15:8];
                    byte_valid <= 1'b1;
                end
                pend   <= rd_val_data[7:0];
                pend_v <= 1'b1;
            end else if (pend_v) begin
                if (data_sector) begin
                    byte_data  <= pend;
                    byte_valid <= 1'b1;
                end
                pend_v <= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (en_s2 && sdi_s2 && !started) begin
                        tbl_rec <= (ix_s2 < 8'd56) ? ix_s2[5:0] : 6'd0;
                        tbl_req <= 1'b1;
                        busy    <= 1'b1;
                        err     <= 1'b0;        // 每次新加载清错误标志
                        err_st  <= 4'd0;        // 顺带清错误现场快照
                        retry   <= 2'd0;
                        pretry  <= 2'd0;
                        wto     <= 17'd0;
                        st      <= S_TBL;
                    end
                end

                S_TBL: begin
                    if (tbl_done) begin
                        tbl_req    <= 1'b0;
                        started    <= 1'b1;
                        cur_clus   <= tbl_data[31:0];
                        bytes_left <= tbl_data[63:32];
                        sec_in     <= 8'd0;
                        bcnt       <= 10'd0;
                        word_cnt   <= 9'd0;
                        bsy        <= 1'b0;
                        wto        <= 17'd0;
                        if ((tbl_data[31:0] < 32'd2) || (tbl_data[31:0] >= 32'h0FFFFFF8) ||
                            (tbl_data[63:32] == 32'd0)) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end else begin
                            st <= S_CMD;
                        end
                    end else begin
                        // ★ 等文件表也要有退路：BRAM 仲裁万一没服务到，
                        //   原来会永久停在 S_TBL，done 永远不来 -> 上层等到看门狗。
                        wto <= wto + 17'd1;
                        if (wto == 17'h1FFFF) begin
                            tbl_req <= 1'b0;
                            err     <= 1'b1;
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            st      <= S_IDLE;
                        end
                    end
                end

                S_CMD: begin
                    // ★ 同上：等上一位使用者的 busy 落干净再发请求
                    if (!rd_busy) begin
                        rd_sec_addr <= data_lba + ((cur_clus - 32'd2) << spc_log2) + {24'd0, sec_in};
                        rd_start_en <= 1'b1;
                        data_sector <= 1'b1;
                        wto         <= 17'd0;
                        st          <= S_WT;
                    end
                end

                S_WT: begin
                    if (rd_busy) begin
                        rd_start_en <= 1'b0;
                        bsy         <= 1'b1;
                        wto         <= 17'd0;
                        st          <= S_RCV;
                    end else begin
                        // 请求发出去 2.6ms 还没看到 busy：撤掉重发
                        wto <= wto + 17'd1;
                        if (wto == 17'h1FFFF) begin
                            rd_start_en <= 1'b0;
                            if (retry == 2'd3) begin
                                // 连续 4 次都没受理：放弃本次加载
                                retry <= 2'd0;
                                err   <= 1'b1;
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                st    <= S_IDLE;
                            end else begin
                                retry <= retry + 2'd1;
                                st    <= S_CMD;
                            end
                        end
                    end
                end

                S_RCV: begin
                    if (rd_val_en) begin
                        wto <= 17'd0;                  // 有数据就重置超时
                        word_cnt <= word_cnt + 9'd1;
                        if (word_cnt == 9'd255) begin
                            bsy   <= 1'b0;
                            retry <= 2'd0;             // 这一扇区成功，清重试计数
                            st    <= S_GAP;
                        end
                    end else if (!rd_busy && (word_cnt != 9'd0)) begin
                        // ★ busy 落下了却没收满 256 个字：**字节流已经错位**。
                        //   已经吐出去的字节收不回来，重读这一扇区只会让后面的像素
                        //   整体偏移（仿真实测：半截传输后重试，图片多出 200 字节、
                        //   223638 个像素错位）。所以这里不重试，直接判整张失败，
                        //   由上层保留上一张继续显示。
                        retry <= 2'd0;
                        err   <= 1'b1;
                        bsy   <= 1'b0;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        st    <= S_IDLE;
                    end else if (!rd_busy) begin
                        // 一个字节都没收到就结束了：安全，可以重发请求
                        if (retry == 2'd3) begin
                            retry <= 2'd0;
                            err   <= 1'b1;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            st    <= S_IDLE;
                        end else begin
                            retry <= retry + 2'd1;
                            st    <= S_CMD;
                        end
                    end else begin
                        // 收到一半卡住了：可能已经错位，直接判失败
                        wto <= wto + 17'd1;
                        if (wto == 17'h1FFFF) begin
                            retry <= 2'd0;
                            err   <= 1'b1;
                            bsy   <= 1'b0;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            st    <= S_IDLE;
                        end
                    end
                end

                S_GAP: begin
                    if (!rd_busy) begin
                        if (sp_s2 || (bytes_left <= 32'd512)) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end else if (fu_s2 >= 9'd64) begin
                            // ★ 这里**不能加短超时**：写 FIFO 是"画面消隐期才排空"的，
                            //   一次正常的等待就可能跨一整帧（33ms）。
                            //   上板实测：加 2.6ms 超时 -> 每个扇区都判失败，
                            //   图片再也不换（数码管 204911）。
                            //   真的卡死由上层的 ld_tmo(3.4s) 兜底。
                            wto <= 17'd0;
                        end else begin
                            wto <= 17'd0;
                            bytes_left <= bytes_left - 32'd512;
                            if (sec_in + 8'd1 < (8'd1 << spc_log2)) begin
                                sec_in   <= sec_in + 8'd1;
                                word_cnt <= 9'd0;
                                bsy      <= 1'b0;
                                st       <= S_CMD;
                            end else begin
                                foff <= {24'd0, cur_clus[6:0]} << 2;
                                st   <= S_F0;
                            end
                        end
                    end
                end

                S_F0: begin
                    // ★ 必须等上一位使用者的 busy 落干净再发请求。
                    //   这里是全文件唯一漏掉这道门的地方：rd_start_en 只保持 1 拍，
                    //   撞上别人的传输尾巴就被仲裁器吞掉，S_F1 永远等不到 busy。
                    if (!rd_busy) begin
                        rd_sec_addr <= fat_lba + {23'd0, cur_clus[31:7]};
                        rd_start_en <= 1'b1;
                        bcnt        <= 10'd0;
                        bsy         <= 1'b0;
                        nxt_clus    <= 32'hFFFFFFFF;
                        wto         <= 17'd0;
                        data_sector <= 1'b0;
                        st          <= S_F1;
                    end
                end

                S_F1: begin
                    if (rd_busy) begin
                        rd_start_en <= 1'b0;
                        bsy         <= 1'b1;
                        wto         <= 17'd0;
                        st          <= S_F2;
                    end else begin
                        // ★ 请求没被受理（总线上还有别人的传输）：撤掉重试。
                        //   没有这个超时的话，一次被吞就是永久挂死。
                        wto <= wto + 17'd1;
                        if (wto == 17'h1FFFF) begin
                            rd_start_en <= 1'b0;
                            if (pretry == 2'd3) begin
                                pretry <= 2'd0;
                                err    <= 1'b1;
                                busy   <= 1'b0;
                                done   <= 1'b1;
                                st     <= S_IDLE;
                            end else begin
                                pretry <= pretry + 2'd1;
                                st     <= S_F0;
                            end
                        end
                    end
                end

                S_F2: begin
                    if (fav) begin
                        fav     <= 1'b0;
                        pretry  <= 2'd0;
                        wto     <= 17'd0;
                        if ((nxt_clus >= 32'h0FFFFFF8) || (nxt_clus < 32'd2)) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end else begin
                            cur_clus <= nxt_clus;
                            sec_in   <= 8'd0;
                            word_cnt <= 9'd0;
                            st       <= S_CMD;
                        end
                    end
                    if (bsy && byte_en) begin
                        wto <= 17'd0;
                        if (bcnt == foff[9:0])         nxt_clus[7:0]   <= byte_d;
                        if (bcnt == foff[9:0] + 10'd1) nxt_clus[15:8]  <= byte_d;
                        if (bcnt == foff[9:0] + 10'd2) nxt_clus[23:16] <= byte_d;
                        if (bcnt == foff[9:0] + 10'd3) nxt_clus[31:24] <= byte_d;
                        bcnt <= bcnt + 10'd1;
                        if (bcnt == 10'd511) begin
                            bcnt <= 10'd0;
                            bsy  <= 1'b0;
                            fav  <= 1'b1;
                        end
                    end else begin
                        // ★ 这一扇区没收到数据（busy 不来 / 半截断流）也要退出来，
                        //   否则 fav 永远不会置起，簇链就断在这里。
                        wto <= wto + 17'd1;
                        if (wto == 17'h1FFFF) begin
                            err  <= 1'b1;
                            bsy  <= 1'b0;
                            busy <= 1'b0;
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase

            // ★ 上层撤了 enable：强制回空闲。
            //   原来只清 started/done，st 会留在 S_RCV / S_GAP / S_WT 里；
            //   下一次 enable 拉高时进不了 S_IDLE，加载永远起不来，
            //   只能靠 3.4s 看门狗超时 —— 表现就是"切图反复失败、间隔几十秒"。
            if (!en_s2 && (st != S_IDLE)) begin
                st          <= S_IDLE;
                rd_start_en <= 1'b0;
                bsy         <= 1'b0;
                busy        <= 1'b0;
                pend_v      <= 1'b0;
                tbl_req     <= 1'b0;
                word_cnt    <= 9'd0;
                retry       <= 2'd0;
            end
        end
    end

endmodule
