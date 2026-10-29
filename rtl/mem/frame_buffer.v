// ============================================================================
//  frame_buffer.v —— SDRAM 帧缓存（按 APUG011 的 App 接口约束）
//
//  约束（《APUG011 基于 ERAM 接口实现的高性能 SDRAM 读写 v1.2》）：
//    1. 读写不能同时进行 —— "场消隐写、其余时间读"的相位隔离；
//    2. 读延迟 10 拍 —— 用"在途计数"控制预取深度，不靠 full 标志；
//    3. Sdr_init_ref_vld 为高（刷新）时不能发请求；
//    4. Sdr_busy 时暂停。
//
//  ---------------------------------------------------------------------------
//  2026-10-27 改版：满屏显示（960x540 存储 + 4:3 上采样到 1280x720）
//
//  为什么不是 1280x720 双缓冲：
//    App 地址是 21 位**字节**地址 = 2MB = 512K 字（P7 实测）。
//    720p RGB565 一帧 460,800 字 = 1.84MB，双缓冲 3.7MB —— 物理放不下。
//    2MB 里能双缓冲的最大 16:9 面积 = 262,144 字 = 960x540。
//
//  显示：每条显示行取一条 960 宽的源行，横向 4:3 重采样
//        （每个源像素显示 1~2 次，第 4 个源像素跳过：4 出 3 存）。
//        纵向同理：每 4 条显示行用 3 条源行（第 1 条重复一次）。
//        上采样在**读地址侧**完成，像素域只按"字变化"取数，不需要行缓存。
//
//  时序：帧行 0..15 写（消隐），16..24 读预灌，25..744 读（活动区）。
//        整帧的写需求只有 288K 字/s（SD 限速），16 行窗口有 10 倍余量。
// ============================================================================
`timescale 1ns / 1ps

module frame_buffer #(
    parameter integer FB_W        = 1280,     // 显示分辨率
    parameter integer FB_H        = 720,
    parameter integer VACTIVE     = 720,
    parameter integer V_OFFSET    = 25,       // VSA+VBP：帧内行号 -> 活动区行号
    // 存储区：960x540（2 像素/32bit 字）
    parameter integer SW          = 960,
    parameter integer SH          = 540,
    parameter integer WR_LINES    = 16        // 帧首写窗口行数
)(
    // ---------------- SDRAM App 接口 ----------------
    output wire [20:0] app_wr_addr,
    output wire [31:0] app_wr_din,
    output wire        app_wr_en,
    output wire [20:0] app_rd_addr,
    output wire        app_rd_en,
    input  wire        app_rd_valid,
    input  wire [31:0] app_rd_dout,
    input  wire        app_init_done,
    input  wire        app_ref_vld,
    input  wire        app_busy,

    // ---------------- 时钟 ----------------
    input  wire        clk_mem,
    input  wire        rst_mem,

    // ---------------- 写侧（像素域） ----------------
    input  wire        pix_clk,
    input  wire        pix_rst,
    input  wire        wr_en,
    input  wire [11:0] wr_x,
    input  wire [11:0] wr_y,
    input  wire [15:0] wr_rgb,
    input  wire        wr_buf,
    output wire        wr_ready,

    // ---------------- 读侧（像素域） ----------------
    input  wire        vs,
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire        rd_buf,
    input  wire        load_mode,      // 1=首次加载：整帧只写不读
    input  wire        rd_bank,        // 读缓冲：0=A(字 0 起) 1=B(字 IT 起)
    // 擦除/推入式转场：显示行 < rd_wipe 用 rd_bank（旧图），否则 rd_bank_new（新图）。
    // 正常显示时 rd_wipe = 720 且 rd_bank_new = rd_bank。
    input  wire        rd_bank_new,
    input  wire [19:0] rd_wipe,        // 单位改成**显示行号** 0..720
    input  wire        wr_bank,
    output wire [8:0]  wr_fifo_used,   // 写 FIFO 已用字数（pix 域），给 SD 反压
    output wire        wr_idle,        // 写侧彻底排空（FIFO 空 + 无在途 burst）
    output wire        wr_drop,        // 本拍有像素因写 FIFO 满而丢失（诊断用）
    output wire [7:0]  rd_drop_cnt,    // 读通路丢字计数（饱和）：非 0 就会纵向错行
    output wire [15:0] rgb_out,
    output wire        de_out
);

    // 注意：厂商控制器的 App 地址是**字节地址**（32bit 数据占 4 字节），
    // 所有 App 地址都要 = 字索引 << 2。
    localparam integer IW    = SW / 2;                // 每行字数（480）
    localparam integer IT    = IW * SH;               // 一块缓冲字数（259200）
    localparam [19:0] IT21  = IT;
    localparam [8:0]  IW9   = IW;

    // 双缓冲最大占用：518400 字 = 2,073,600 字节 < 2MB ✔（余 23KB）
    localparam integer WR_END = WR_LINES;             // 写窗口：帧行 0..15
    localparam integer PRE_END = V_OFFSET;            // 预灌：帧行 16..24

    // ==================================================================
    // 像素域：两像素拼成一个 32bit 字
    // ==================================================================
    reg        pv;                 // 有一个待配对的偶数像素
    reg [15:0] prgb;
    reg [11:0] py;
    reg        pb;

    wire pair_now = pv && (py == wr_y) && (pb == wr_buf) && wr_x[0];

    wire        wf_full, wf_empty, wf_rvld;
    wire [55:0] wf_dout;
    wire        wf_wr;
    wire [55:0] wf_data;
    wire        wf_rd;

    // 写使能与数据都必须是组合的：若把 ~wf_full 判断寄存一拍，
    // FIFO 接近满时会出现"判断时不满、写入时已满"，像素被静默丢弃。
    assign wf_wr   = pair_now && ~wf_full;
    assign wf_data = {wr_buf, wr_y, wr_x[11:1], prgb, wr_rgb};

    wire [8:0] wf_used;

    // 写侧流水级（FIFO 输出 -> 组装器，见下面的时序说明）
    reg        a_vld;
    reg [55:0] a_dat;
    reg [10:0] exp_xw;         // 组内期望的下一列号

    // 深度保持 256：曾试过 512，多占 2 块 M9K 后布局变化导致画面整体错位，
    // 已回退（BRAM 余量比 FIFO 深度更重要）。
    afifo #(.DW(56), .AW(8)) u_wfifo (
        .clk_w(pix_clk), .clk_r(clk_mem), .aclr(pix_rst),
        .wr_en(wf_wr), .wr_data(wf_data), .wr_full(wf_full),
        .rd_en(wf_rd), .rd_data(wf_dout), .rd_empty(wf_empty),
        .rd_valid(wf_rvld), .wr_used(wf_used)
    );

    assign wr_fifo_used = wf_used;          // 9 位直通，禁止截断

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            pv   <= 1'b0;
            prgb <= 16'd0;
            py   <= 12'd0;
            pb   <= 1'b0;
        end else if (wr_en && !wf_full) begin
            if (!wr_x[0]) begin
                prgb <= wr_rgb;
                py   <= wr_y;
                pb   <= wr_buf;
                pv   <= 1'b1;
            end else if (pair_now) begin
                pv <= 1'b0;
            end
        end
    end

    assign wr_ready = ~wf_full;
    assign wr_drop  = wr_en & wf_full;      // 丢了就是丢了，先数出来


    // ==================================================================
    // 写窗口：图片铺满整个活动区，只有消隐期能写
    //   帧行 0..15  -> 写
    //   帧行 16..24 -> 读预灌（清空后的读 FIFO 在这里灌满）
    //   帧行 25..744 -> 读（活动区）
    // ==================================================================
    localparam [11:0] WR_END12 = WR_END;
    wire       wr_window = load_mode | (y < WR_END12);
    reg  [2:0] ww_sync;
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) ww_sync <= 3'b000;
        else         ww_sync <= {ww_sync[1:0], wr_window};
    end
    wire wr_win_m = ww_sync[2];

    // ==================================================================
    // mem 域取字 + 4 字 burst 打包（写侧逻辑与旧版一致）
    // ==================================================================
    wire        wpop;          // = wf_rd，仅作观测名
    reg         wvld;
    reg  [2:0]  bn;
    reg  [31:0] bb0, bb1, bb2, bb3;
    reg  [20:0] baddr;
    reg  [11:0] b_y;
    reg  [10:0] b_xw;
    reg         bsend;
    reg  [1:0]  bi;
    reg  [3:0]  bgap;
    reg         ww_d;
    reg  [5:0]  rq, wq;
    reg         rburst;

    reg [22:0]  idle_tmr;
    // 23 位全 1 的与运算有 4~5 级 LUT，直接连到 bn/bb* 的时钟使能会超 8ns
    // （TD 报过 idle_tmr[12] -> bb1_reg[11].ce，7 级逻辑 8.10ns，-0.46ns）。
    // 把"超时"先打一拍：67ms 的超时晚一拍毫无影响，但路径从寄存器出发。
    reg         idle_tmo;
    wire        tail_drop = idle_tmo && (bn != 3'd0);

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem)                          idle_tmr <= 23'd0;
        else if (!wf_empty || bsend || a_vld)  idle_tmr <= 23'd0;
        else if (idle_tmr != 23'h7FFFFF)      idle_tmr <= idle_tmr + 23'd1;
    end

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) idle_tmo <= 1'b0;
        else         idle_tmo <= (idle_tmr == 23'h7FFFFF);
    end

    // ------------------------------------------------------------------
    // ★ 2026-10-27：FIFO 输出先打一拍再进组装器
    //   TD 报告里 clk_mem 最差路径是 "wfifo EMB clk2q 3.2ns -> dy/xw 比较
    //   -> bn"，SWNS -2.24ns。afifo 的 RAM 输出是 3.2ns 的慢路径，后接
    //   11 位比较必然超。加一级寄存器后，比较从寄存器出发（0.4ns），
    //   125MHz 余量回到 1ns 以上。写通路不在乎这 1 拍延迟。
    // ------------------------------------------------------------------
    wire [11:0] a_y   = a_dat[54:43];
    wire [10:0] a_xw  = a_dat[42:32];
    wire [31:0] a_rgb = a_dat[31:0];

    wire [9:0]  dy         = a_y[9:0];                // 0..539
    wire [8:0]  dxw        = a_xw[8:0];               // 0..479
    // 480 = 512 - 32，移位加减，避免 125MHz 上的乘法器
    wire [18:0] row_base   = ({9'd0, dy} << 9) - ({9'd0, dy} << 5);
    wire [18:0] word_raw   = row_base + {10'd0, dxw};
    wire [20:0] wr_bank_off = wr_bank ? {1'b0, IT21} : 21'd0;
    wire [20:0] word_addr   = {word_raw[18:0], 2'b00} +
                              {wr_bank_off[18:0], 2'b00};
    wire        bfull      = (bn == 3'd4);
    wire        badr_ok    = (a_xw[1:0] == 2'b00);
    // 组内连续性：不比较地址和，改用"期望列号"寄存器，再省一个加法器
    wire        addr_cont  = (bn == 3'd0) ||
                             ((a_y == b_y) && (a_xw == exp_xw));
    wire        can_accept = ~bsend & ~bfull & (bgap == 4'd0);
    wire        wd_useful  = (bn == 3'd0) ? badr_ok : addr_cont;
    wire        wd_take    = a_vld & can_accept & wd_useful;
    wire        wd_drop    = a_vld & can_accept & ~wd_useful;

    reg  wfly;

    // ★ 写 FIFO 出队不再只在"帧首 16 行"里做。
    //   wr_win_m 在读侧是"整段复位"（清读 FIFO + 行游标归零），只属于帧首；
    //   但出队/突发完全可以放在任意时刻：写突发本来就被 wq 限速成
    //   每 64 拍一次 4 字，读侧只用掉约 9% 带宽，1024 字的读 FIFO 足够吸收。
    //   旧写法把两者绑在一起，导致读一张图时源被限成"每帧 256 像素"，
    //   一张 960x540 要等上千帧（这就是切图几十秒的根因）。
    assign wf_rd = ~wf_empty & ~a_vld & ~wfly;

    // ------------------------------------------------------------------
    // 读优先：显示侧读 FIFO 见底时，写突发先让路。
    //   背景：清屏 / 读图产生的写突发会长时间占住 SDRAM，而读侧按 (wq==63)
    //   的**固定时隙**取数；时隙一旦被 app_busy 挡掉，就要再等 64 拍。
    //   读 FIFO 只有 1024 字（≈2 行），连丢几个时隙就会饿死 ——
    //   上板表现正是"按下切屏那一瞬间画面撕裂"。
    //   sim/tb_tear.v 复现：整帧后台写入期间 77 万像素里 77 万错、starve 28.9 万。
    //   这里让写侧在 FIFO 水位 < 768 时暂停；首张 / 单缓冲时 load_mode=1，
    //   读侧本来就关着，不受这个门控。
    // ------------------------------------------------------------------
    wire [11:0] rf_used;
    reg  [1:0]  lm_sync;
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) lm_sync <= 2'b00;
        else         lm_sync <= {lm_sync[0], load_mode};
    end
    wire wr_ok = (rf_used >= 12'd768) | lm_sync[1];
    assign wpop  = wf_rd;

    wire [31:0] bsel = (bi == 2'd0) ? bb0 :
                       (bi == 2'd1) ? bb1 :
                       (bi == 2'd2) ? bb2 : bb3;

    assign app_wr_en   = bsend;
    assign app_wr_addr = baddr + {19'd0, bi};
    assign app_wr_din  = bsel;

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            a_vld <= 1'b0;
            a_dat <= 56'd0;
            wfly  <= 1'b0;
        end else begin
            wfly <= wf_rd;
            if (wf_rvld && !a_vld) begin
                a_vld <= 1'b1;                    // 数据回来了，挂到下一级
                a_dat <= wf_dout;
            end else if (a_vld && can_accept) begin
                a_vld <= 1'b0;                    // 被收下（或按规则丢弃）
            end
        end
    end

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            bb0 <= 32'd0; bb1 <= 32'd0; bb2 <= 32'd0; bb3 <= 32'd0;
            bn <= 3'd0; baddr <= 21'd0; bsend <= 1'b0; bi <= 2'd0;
            bgap <= 4'd0; ww_d <= 1'b0; b_y <= 12'd0; b_xw <= 11'd0;
            exp_xw <= 11'd0;
        end else begin
            ww_d <= wr_win_m;

            if (bsend) begin
                if (bi == 2'd3) begin
                    bsend <= 1'b0;
                    bi    <= 2'd0;
                    bgap  <= 4'd1;
                end else begin
                    bi <= bi + 2'd1;
                end
            end else if (bgap != 4'd0) begin
                bgap <= bgap - 4'd1;
            end else if (bfull && app_init_done && ~app_ref_vld && ~app_busy &&
                         (rq == 6'd63) && ~rburst && wr_ok) begin
                bsend <= 1'b1;
                bi    <= 2'd0;
                bn    <= 3'd0;
            end else if (tail_drop) begin
                bn <= 3'd0;
            end else if (wd_drop) begin
                bn <= 3'd0;
            end else if (wd_take) begin
                case (bn)
                    3'd0: begin
                        bb0    <= a_rgb;
                        baddr  <= word_addr;
                        b_y    <= a_y;
                        b_xw   <= a_xw;
                        exp_xw <= a_xw + 11'd1;
                    end
                    3'd1: begin bb1 <= a_rgb; exp_xw <= a_xw + 11'd1; end
                    3'd2: begin bb2 <= a_rgb; exp_xw <= a_xw + 11'd1; end
                    default: begin bb3 <= a_rgb; exp_xw <= a_xw + 11'd1; end
                endcase
                bn <= bn + 3'd1;
            end
        end
    end

    // ==================================================================
    // 读侧
    // ==================================================================
    wire        rf_full, rf_empty, rf_rd;
    reg         rf_wr;
    reg  [31:0] rd_cap;
    wire [31:0] rf_dout;

    afifo #(.DW(32), .AW(11)) u_rfifo (
        .clk_w(clk_mem), .clk_r(pix_clk), .aclr(wr_win_m | pix_rst),
        .wr_en(rf_wr), .wr_data(rd_cap), .wr_full(rf_full),
        .rd_en(rf_rd), .rd_data(rf_dout), .rd_empty(rf_empty),
        .rd_valid(), .wr_used(rf_used)
    );

    // 读地址游标：显示行 -> 源行（4:3 纵向重采样）
    //   rout 0,1,2,3,4,5,... -> 源行 0,0,1,2,3,3,...
    //   即"当前行号 rout[1:0]==0 时，下一行重复本行"
    reg  [9:0]  rcol;      // 行内字号 0..479
    reg  [9:0]  rrow;      // 源行 0..539
    reg  [9:0]  rout;      // 显示行 0..719

    wire [18:0] rrow_base = ({9'd0, rrow} << 9) - ({9'd0, rrow} << 5);
    wire [19:0] rword     = {1'b0, rrow_base} + {10'd0, rcol};

    // 4:3 转场分界：显示行与 rd_wipe 比较，整条行要么旧图要么新图
    wire        rd_bank_eff = (rout < rd_wipe) ? rd_bank : rd_bank_new;
    wire [20:0] rd_bank_off = rd_bank_eff ? {1'b0, IT21} : 21'd0;
    assign app_rd_addr = {rword[18:0], 2'b00} + {rd_bank_off[18:0], 2'b00};

    reg  [1:0] rbi;
    reg  [3:0] rgap;

    reg [11:0] rf_used_r;
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) rf_used_r <= 12'd0;
        else         rf_used_r <= rf_used;
    end

    // 读通路丢字计数：只统计"FIFO 真满了还回来数据"这种**会错行**的丢弃。
    // 写窗口开头那几拍的在途数据虽然也被丢，但那时 FIFO 反正要清空、
    // 行游标也要归零，不影响对齐，所以不计入。
    // 数码管左两位能看到这个值，正常必须一直是 00。
    reg [7:0] rdrop;
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem)                                 rdrop <= 8'd0;
        else if (app_rd_valid & rf_full & ~wr_win_m)
            rdrop <= (rdrop == 8'hFF) ? rdrop : rdrop + 8'd1;
    end
    assign rd_drop_cnt = rdrop;

    // ★ 预灌门限从 2032 降到 1024（一半）。
    //   原来只留 16 个字的余量：burst 在途 4 字 + rf_used 跨时钟同步滞后，
    //   硬件上 SDRAM 刷新/仲裁一挤就会真的冲到 2048 满，而下面
    //   "rf_wr <= app_rd_valid & ~rf_full" 会**静默丢掉**这个字。
    //   丢掉 N 个字 -> 之后所有像素提前 N 个字 -> 整幅图纵向错 N/480 行，
    //   而且每帧丢的个数不同 -> 上板看到的"整幅画面上下轻微跳动/错行"。
    //   1024 字 ≈ 73us 的消耗量，读写带宽差 5 倍以上，留这么多完全够。
    wire rstart = ~wr_win_m & app_init_done & ~app_ref_vld & ~app_busy &
                  (rf_used_r < 12'd1024) & ~rf_full & ~rburst & (rgap == 4'd0) &
                  ~bsend & (wq == 6'd63);

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            rburst <= 1'b0;
            rbi    <= 2'd0;
            rgap   <= 4'd0;
        end else if (rburst) begin
            if (rbi == 2'd2) begin      // rstart 发第 1 拍，rbi 0..2 再发 3 拍 = 共 4 字
                rburst <= 1'b0;
                rbi    <= 2'd0;
                rgap   <= 4'd1;
            end else begin
                rbi <= rbi + 2'd1;
            end
        end else if (rgap != 4'd0) begin
            rgap <= rgap - 4'd1;
        end else if (rstart) begin
            rburst <= 1'b1;
            rbi    <= 2'd0;
        end
    end

    wire rd_go = rstart | rburst;

    assign app_rd_en = rd_go;

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            rf_wr  <= 1'b0;
            rd_cap <= 32'd0;
            rcol   <= 10'd0;
            rrow   <= 10'd0;
            rout   <= 10'd0;
        end else begin
            rf_wr <= app_rd_valid & ~wr_win_m & ~rf_full;
            if (app_rd_valid)
                rd_cap <= app_rd_dout;

            if (wr_win_m) begin
                rcol <= 10'd0;
                rrow <= 10'd0;
                rout <= 10'd0;
            end else if (rd_go) begin
                // 每个 rd_go 拍产生**一个字**（4 拍 burst = 4 个字）
                if (rcol == 10'd479) begin
                    rcol <= 10'd0;
                    if (rout == 10'd719) begin
                        rout <= 10'd0;
                        rrow <= 10'd0;
                    end else begin
                        rout <= rout + 10'd1;
                        // 显示行 0/4/8... 之后的下一行重复同一条源行
                        if (rout[1:0] != 2'd0)
                            rrow <= rrow + 10'd1;
                    end
                end else begin
                    rcol <= rcol + 10'd1;
                end
            end
        end
    end

    // ==================================================================
    // 像素域：满屏输出，横向 4:3 重采样
    //   显示 x -> 源像素 spx = (3x)>>2（0..959）
    //   一个字装两个源像素，所以"字号" = spx>>1 = (3x)>>3
    //   在字号即将变化的那一拍提前取下一个字（afifo 输出寄存一拍）
    // ==================================================================
    reg        primed;

    wire [12:0] sx3  = {1'b0, x} + {1'b0, x, 1'b0};     // 3x，最大 3837
    wire [11:0] spx  = sx3[12:2];                       // (3x)>>2
    wire        half = spx[0];
    wire [12:0] sx3n = sx3 + 13'd3;
    wire        pop  = de && (sx3n[12:3] != sx3[12:3]); // 下一拍字号变化

    assign rf_rd   = (~de & ~primed & ~rf_empty) |
                     (de & pop & ~rf_empty);
    // 写侧把"偶数像素"放在高半字、"奇数像素"放在低半字，
    // 所以读侧偶数像素取 rf_dout[31:16]、奇数像素取 [15:0]（与旧版相反，
    // 旧版把每一对像素左右互换了，只是 1px 的差别一直没被发现）。
    assign rgb_out = de ? (half ? rf_dout[15:0] : rf_dout[31:16]) : 16'd0;
    assign de_out  = de;

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            primed <= 1'b0;
        end else begin
            if (vs)
                primed <= 1'b0;
            else if (rf_rd)
                primed <= 1'b1;

        end
    end

    // 读写方向切换的静默计数：读 burst 停了 63 拍才允许发写 burst，反之亦然。
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            rq <= 6'd63;
            wq <= 6'd63;
        end else begin
            rq <= rd_go ? 6'd0 : ((rq == 6'd63) ? rq : (rq + 6'd1));
            wq <= bsend ? 6'd0 : ((wq == 6'd63) ? wq : (wq + 6'd1));
        end
    end

    assign wr_idle = wf_empty & ~bsend & (bn == 3'd0) & ~a_vld & ~wfly;

endmodule
