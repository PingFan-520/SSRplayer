// ============================================================================
//  frame_buffer.v —— SDRAM 帧缓存（按 APUG011 的 App 接口约束）
//
//  约束（《APUG011 基于 ERAM 接口实现的高性能 SDRAM 读写 v1.2》）：
//    1. 读写不能同时进行 —— "场消隐写、其余时间读"的相位隔离；
//    2. 读延迟 10 拍 —— 用"在途计数"控制预取深度，不靠 full 标志；
//    3. Sdr_init_ref_vld 为高（刷新）时不能发请求；
//    4. Sdr_busy 时暂停。
//
//  说明：读写使能是**组合输出**，与 ref_vld/busy 同拍判断，
//        避免"寄存一拍"造成的相位错位（否则每次刷新都会撞一次）。
//
//  存储：1280x720 RGB565，2 像素/32bit 字，640 字/行，一帧 460,800 字。
//
//  相位（720p）：y 传**帧内行号**（0..749），而不是活动区坐标。
//    - 正常显示：只有帧首 WR_LINES(25) 行消隐写，其余时间读
//    - load_mode=1：整帧只写不读，用于"加载一张图"
//
//  为什么需要 load_mode：实测 Sdr_busy 占 76%，写窗口只占 3%，
//  两者相乘 → 每帧只能写约 1900 字，写满一帧要 80 帧。
//  加载期停读后 busy 归零、窗口 100%，一帧（16.5ms）就能写完 46 万字。
// ============================================================================
`timescale 1ns / 1ps

module frame_buffer #(
    parameter integer FB_W        = 1280,     // 显示分辨率
    parameter integer FB_H        = 720,
    parameter integer VACTIVE     = 720,
    parameter integer WR_LINES    = 25,       // 帧首消隐行数（写窗口）
    parameter integer V_OFFSET    = 25,       // VSA+VBP：帧内行号 -> 活动区行号
    // 图片区域（只存这块，黑边直接输出 0，省 2/3 读带宽）
    parameter integer IMG_W       = 640,
    parameter integer IMG_H       = 480,
    parameter integer IMG_X0      = 320,
    parameter integer IMG_Y0      = 120
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
    input  wire        rd_bank,        // 读缓冲：0=A(字 0 起) 1=B(字 153600 起)
    input  wire        wr_bank,        // 写缓冲：另一块
    // 9 位：afifo 的 wr_used 是 [AW:0]，满的时候等于 256。
    // 曾经截成 8 位 -> 满时变 0 -> SD 读到"空"，像素全丢、整张图写不进去。
    output wire [8:0]  wr_fifo_used,   // 写 FIFO 已用字数（pix 域），给 SD 反压
    output wire        wr_idle,        // 写侧彻底排空（FIFO 空 + 无在途 burst）
    output wire        wr_drop,        // 本拍有像素因写 FIFO 满而丢失（诊断用）
    output wire [15:0] rgb_out,
    output wire        de_out
);

    // 注意：厂商控制器的 App 地址是**字节地址**（32bit 数据占 4 字节），
    // 实测写 addr=76960 落在 SDRAM 索引 19240（= 76960/4）。
    // 因此所有 App 地址都要 = 字索引 << 2。
    // 21 位字节地址只能覆盖 2MB = 512K 字，够一帧（460800 字），不够双缓冲。
    // 注意：厂商控制器的 App 地址是**字节地址**（32bit 数据占 4 字节），
    // 实测写 addr=76960 落在 SDRAM 索引 19240（= 76960/4）。
    // 因此所有 App 地址都要 = 字索引 << 2。
    //
    // 存储只放图片区域（IMG_W x IMG_H），黑边不进 SDRAM：
    //   720p60 全屏读要 27.6M 字/s，而控制器实测只有 27.5M（busy 77%），刚好不够；
    //   只读图片区域只要 9.2M 字/s，余量 3 倍。
    localparam integer IW    = IMG_W / 2;             // 图片每行字数
    localparam integer IT    = IW * IMG_H;            // 图片总字数
    localparam [8:0]  IW9   = IW;                     // 9 位（<=511 字/行）
    localparam [19:0] IT_1  = IT - 1;
    localparam [10:0] X0W   = IMG_X0 / 2;             // 图片左边界的字偏移
    localparam [11:0] Y0W   = IMG_Y0;                 // 图片上边界
    localparam [11:0] WB    = WR_LINES;               // 帧首消隐行数 = 写窗口
    localparam [20:0] IT21  = IT;                     // 一块缓冲的字数（bank 偏移）
    // 双缓冲：写窗口改成"图片行之外"，图片区留给读，两者在时间上完全不重叠
    localparam integer IMG_TOP = IMG_Y0 + V_OFFSET;
    localparam integer IMG_BOT = IMG_Y0 + V_OFFSET + IMG_H;

    // ==================================================================
    // 像素域：两像素拼成一个 32bit 字（偶数像素在低半，奇数在高半）
    //   拼好后连同 (buf, y, x/2) 一起写入跨时钟 FIFO，
    //   mem 域拿到的就是"可直接写 SDRAM 的字"，不需要再配对。
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

    wire        wd_buf = wf_dout[55];
    wire [11:0] wd_y   = wf_dout[54:43];
    wire [10:0] wd_xw  = wf_dout[42:32];
    wire [31:0] wd_rgb = wf_dout[31:0];

    // ==================================================================
    // 写窗口：首次加载时整帧可写；正常运行时只写"图片行之外"的 270 行
    //   图片区 480 行的读需求是 7.2M 字/s，控制器只有 7.5M，
    //   读写必须时间分离：图片区给读，其余 270 行（11.9ms）给写。
    // ==================================================================
    wire       in_img_rows = (y >= IMG_TOP[11:0]) && (y < IMG_BOT[11:0]);
    wire       wr_window   = load_mode | ~in_img_rows;
    reg  [2:0] ww_sync;
    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) ww_sync <= 3'b000;
        else         ww_sync <= {ww_sync[1:0], wr_window};
    end
    wire wr_win_m = ww_sync[2];

    // ==================================================================
    // mem 域取字 + 4 字 burst 打包
    //
    // 实测（tb_sdram_pin_gap）：厂商控制器要求 App_wr_en 连续 4 拍构成
    // 一次 burst；中间插空拍时引脚上 WR 命令数 = 0，整组写被丢弃。
    //
    // afifo 是寄存器输出（rd_en 后一拍数据才有效），所以用
    // pop -> valid 的两拍链路取字，再攒 4 个字连续发 4 拍。
    // 前提：写入起始地址 4 字对齐（640x480 居中 -> x=320 -> word 160）。
    // ==================================================================
    reg         wpop;
    reg         wvld;
    reg  [2:0]  bn;
    reg  [31:0] bb0, bb1, bb2, bb3;
    reg  [20:0] baddr;
    reg  [11:0] b_y;           // 本组起始行
    reg  [10:0] b_xw;          // 本组起始字列
    reg         bsend;
    reg  [1:0]  bi;
    reg  [3:0]  bgap;          // burst 之间的 NOP 间隔（背靠背会被控制器忽略）
    reg         ww_d;

    // 尾部残组：流结束后可能只剩 1~3 个字凑不满 4 字 burst。
    // 若不处理，bn 永远 != 0 -> wr_idle 不拉高 -> 上层永远等不到"加载完成"，
    // 只能靠看门狗收尾（上板表现：一直停在 LOAD、画面反复闪）。
    // FIFO 空且无 burst 持续 256 拍，就把残组丢掉。
    // 超时值要大于"两个字之间的最大间隔"：
    //   正常源一个 32bit 字约 3.8us；写窗口关闭时 FIFO 是满的（wf_empty=0），
    //   所以只有"流真的结束"才会连续 67ms 空。2^23 / 125MHz = 67ms。
    reg [22:0]  idle_tmr;
    wire        tail_drop = (idle_tmr == 23'h7FFFFF) && (bn != 3'd0);

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem)                          idle_tmr <= 23'd0;
        else if (!wf_empty || bsend || wvld)   idle_tmr <= 23'd0;
        else if (idle_tmr != 23'h7FFFFF)       idle_tmr <= idle_tmr + 23'd1;
    end

    // 紧凑存储：图片内坐标（去掉居中偏移）
    // 注意位宽：参数 IMG_Y0 / IMG_X0 是 32 位 integer，若直接和 12 位信号混算，
    // 表达式的位宽推导在仿真（32 位有符号）和综合（按实际位宽裁剪）之间可能不一致。
    // 这里全部先减成明确位宽再乘：dy 0..479（9 位有效）、IW 320（9 位）、
    // 乘积最大 153280（18 位），最后加到 21 位。
    wire [11:0] dy12       = wd_y - Y0W;
    wire [8:0]  dy         = dy12[8:0];
    wire [10:0] dxw        = wd_xw - X0W;
    wire [17:0] row_base   = dy * IW9;
    wire [20:0] word_raw   = {3'd0, row_base} + {10'd0, dxw};
    wire [20:0] wr_bank_off = wr_bank ? IT21 : 21'd0;
    wire [20:0] word_addr   = {word_raw[18:0], 2'b00} +
                              {wr_bank_off[18:0], 2'b00};  // 字索引 + bank 偏移
    wire        bfull      = (bn == 3'd4);
    // 4 字 burst 要求：起始字索引 4 对齐，且组内地址连续（同 行、xw 递增）
    wire        badr_ok    = (wd_xw[1:0] == 2'b00);
    wire        addr_cont  = (bn == 3'd0) ||
                             ((wd_y == b_y) && (wd_xw == b_xw + {8'd0, bn}));
    wire        can_accept = ~bsend & ~bfull & (bgap == 4'd0);
    // 地址不连续/不对齐的字**绝不写**：burst 是"从 baddr 连续写 4 个"，
    // 一旦组内混进别的行/别的列的字，它会被写到 baddr+bn 这个错误地址上，
    // 表现为图像局部整体错位（上板看到的就是"多张图叠拼"）。
    // 宁可丢这 1~3 个字（留下空洞），也不能写错地址。
    // 组首只要求 4 字对齐；组内要求地址连续（addr_cont 里已含 bn==0 的情形）。
    // 注意不能写成 badr_ok & addr_cont：badr_ok 只对组首有意义，
    // 组内第 2~4 个字的 xw 低两位必然非 0，那样会把整组后 3 个字全丢掉。
    wire        wd_useful  = (bn == 3'd0) ? badr_ok : addr_cont;
    wire        wd_take    = wvld & can_accept & wd_useful;
    wire        wd_drop    = wvld & can_accept & ~wd_useful;   // 不对齐/不连续，丢弃整组

    assign wf_rd = wpop;

    wire [31:0] bsel = (bi == 2'd0) ? bb0 :
                       (bi == 2'd1) ? bb1 :
                       (bi == 2'd2) ? bb2 : bb3;

    assign app_wr_en   = bsend;
    assign app_wr_addr = baddr + {19'd0, bi};
    assign app_wr_din  = bsel;

    // wvld 直接来自 FIFO 的 rd_valid（与 dout 同拍），不能用 wpop 再生：
    // FIFO 接近空时 rd_empty 同步滞后，只看 wpop 会把同一个字取两次。
    always @(*) wvld = wf_rvld;

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) wpop <= 1'b0;
        else         wpop <= wr_win_m & ~wf_empty & ~wvld & can_accept;
    end

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            bb0 <= 32'd0; bb1 <= 32'd0; bb2 <= 32'd0; bb3 <= 32'd0;
            bn <= 3'd0; baddr <= 21'd0; bsend <= 1'b0; bi <= 2'd0;
            bgap <= 4'd0; ww_d <= 1'b0; b_y <= 12'd0; b_xw <= 11'd0;
        end else begin
            ww_d <= wr_win_m;

            if (bsend) begin
                if (bi == 2'd3) begin
                    bsend <= 1'b0;
                    bi    <= 2'd0;
                    // burst 之间必须留 1 拍 NOP：
                    // tb_sdram_readscan 实测，背靠背（gap=0）时控制器只落首字/丢整组，
                    // 留 1 拍后行内 63/64 个 burst 全部正确。
                    bgap  <= 4'd1;
                end else begin
                    bi <= bi + 2'd1;
                end
            end else if (bgap != 4'd0) begin
                bgap <= bgap - 4'd1;
            // 关键：burst 只能在"写窗口"里发。
            // APUG011 明确要求读写不能同时进行；双缓冲后 FIFO 里长期有积压，
            // 若不加 wr_win_m 门控，读相位里也会冒出写 burst，
            // 控制器会把命令丢掉/串行错（实测 40 个 burst 没落盘，
            // 上板表现就是整屏花屏、多张图叠拼）。
            end else if (bfull && app_init_done && ~app_ref_vld && ~app_busy && wr_win_m) begin
                bsend <= 1'b1;
                bi    <= 2'd0;
                bn    <= 3'd0;
            end else if (tail_drop) begin
                bn <= 3'd0;              // 流已结束，残组丢弃（尾部 1~3 个字）
            end else if (wd_drop) begin
                bn <= 3'd0;              // 地址跳变/不对齐，丢弃整组残留
            end else if (wd_take) begin
                case (bn)
                    3'd0: begin
                        bb0   <= wd_rgb;
                        baddr <= word_addr;
                        b_y   <= wd_y;
                        b_xw  <= wd_xw;
                    end
                    3'd1: bb1 <= wd_rgb;
                    3'd2: bb2 <= wd_rgb;
                    default: bb3 <= wd_rgb;
                endcase
                bn <= bn + 3'd1;
            end

            // 这里原来在"写窗口关闭"时把 bn 清 0，相当于丢掉正在攒的那 1~3 个字。
            // 双缓冲下窗口每帧开合两次，光这一项每帧就丢几个字（实测 160/153600）。
            // 窗口关闭只是"暂停弹出"，FIFO 里的字还是连续地址，组状态必须保留。
        end
    end

    // ==================================================================
    // 读 FIFO 与在途计数
    // ==================================================================
    wire        rf_full, rf_empty, rf_rd;
    reg         rf_wr;
    reg  [31:0] rd_cap;
    reg  [11:0] occ;
    wire [31:0] rf_dout;

    // 2026-10-24：深度 1024 -> 2048 字，并改用 FIFO 自己的 wr_used 做限流。
    // 深度 4096 -> 2048：4096 要 15 块 M9K，布局时把 u_rfifo 挤到布线拥塞，
    // phy 直接报 "Incremental route failed"。2048 只占 7 块，
    // 6.3 行缓冲在 wr_used 精确限流下足够（之前的失败是 fcnt 漂移，不是深度）。
    wire [11:0] rf_used;
    afifo #(.DW(32), .AW(11)) u_rfifo (
        .clk_w(clk_mem), .clk_r(pix_clk), .aclr(wr_win_m | pix_rst),
        .wr_en(rf_wr), .wr_data(rd_cap), .wr_full(rf_full),
        .rd_en(rf_rd), .rd_data(rf_dout), .rd_empty(rf_empty),
        .rd_valid(), .wr_used(rf_used)
    );

    reg [19:0] rd_cnt;

    // 读也必须**连续 4 拍**构成一次 burst（与写同理）：
    // 若被 occ/busy 打断成 1~3 拍，控制器会返回错位数据，
    // 表现为"每 16 字有 3 个字内容偏"，图像上就是每 32 像素错 6 个。
    //
    // 2026-10-24 实测否掉了"加长到 16 字"的想法：
    //   burst_cycles=1288170 / busy_in_burst=1030536 -> 控制器在连续读的第 5 拍起
    //   就拉高 Sdr_busy，busy 期间的读命令被丢弃，图像只剩 1.4% 正确。
    //   所以这里必须严格 4 拍一组，且每组的起点要等 busy 落下。
    reg  [1:0] rbi;
    reg        rburst;
    reg  [3:0] rgap;             // 跨 SDRAM 行时的间隔（PRE + ACT）

    // ==================================================================
    // FIFO 占用限流（clk_mem 域）
    //
    //   直接取 afifo 的 wr_used，不再用"消费脉冲累加"估算。
    //   历史教训：用 rf_rd 打两拍做减计数时，跨域同步边界会把单拍脉冲
    //   展宽或漏拍，误差永久漂移（实测 fcnt 漂到 2049 > 深度 2048），
    //   于是读侧长期停在"以为满了"的状态，FIFO 却是空的 —— 图像只剩 1.4%。
    // ==================================================================
    // TB 仍按旧名字观测
    wire [11:0] fcnt = rf_used;


    // 只靠 FIFO 的 full 做保护：实测加任何额外水位限流都会让读"读4字就停"，
    // 反而降低有效带宽（fcnt 阈值 512/900 时读只有 125K 字/帧）。
    // 说明：曾试过"FIFO 占用 + 在途"联合限流，但 rstart 依赖 used、
    // used 依赖 outst、outst 又依赖 rd_go/rstart，形成组合环，不能这么写。
    // fcnt 现在是准的（单拍计数），阈值留 16 字余量给 burst 在途数据。
    // 额外加 ~bsend：写 burst 在飞的 4 拍里不能起读，
    // 否则窗口边界处会出现"读写同时"（APUG011 禁止）
    wire       rstart = ~wr_win_m & app_init_done & ~app_ref_vld & ~app_busy &
                        (rf_used < 12'd2032) & ~rf_full & ~rburst & (rgap == 4'd0) &
                        ~bsend;

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            rburst <= 1'b0;
            rbi    <= 2'd0;
            rgap   <= 4'd0;
        end else if (rburst) begin
            if (rbi == 2'd2) begin      // rstart 发第 1 拍，rbi 0..2 再发 3 拍 = 共 4 字
                rburst <= 1'b0;
                rbi    <= 2'd0;
                // 每个读 burst 之后都要留 NOP：
                // tb_sdram_readscan 实测，背靠背读（gap=0）会错 19%，
                // 4 拍 burst + 间隔后完全正确。
                // 统一 1 拍间隔。
                rgap <= 4'd1;
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

    assign app_rd_en   = rd_go;
    wire [20:0] rd_raw  = {1'b0, rd_cnt};
    wire [20:0] rd_bank_off = rd_bank ? IT21 : 21'd0;
    assign app_rd_addr = {rd_raw[18:0], 2'b00} +
                         {rd_bank_off[18:0], 2'b00};

    always @(posedge clk_mem or posedge rst_mem) begin
        if (rst_mem) begin
            rf_wr  <= 1'b0;
            rd_cap <= 32'd0;
            occ    <= 11'd0;
            rd_cnt <= 20'd0;
        end else begin
            rf_wr <= app_rd_valid & ~wr_win_m & ~rf_full;
            if (app_rd_valid)
                rd_cap <= app_rd_dout;

            if (wr_win_m)
                occ <= 11'd0;
            else if (rd_go && !(app_rd_valid & ~rf_full))
                occ <= occ + 11'd1;
            else if (!rd_go && (app_rd_valid & ~rf_full) && (occ != 11'd0))
                occ <= occ - 11'd1;

            if (wr_win_m)
                rd_cnt <= 20'd0;
            else if (rd_go)
                rd_cnt <= (rd_cnt == IT_1) ? 20'd0 : (rd_cnt + 20'd1);
        end
    end

    // ==================================================================
    // 像素域：只显示图片区域，黑边直接输出 0
    //   图片区域内每对像素消费一个字；区域外不消费，黑边也不读 SDRAM。
    // ==================================================================
    reg        pre;
    reg [15:0] hi;

    wire [11:0] ya     = y - V_OFFSET;               // 帧内行号 -> 活动区行号
    wire        in_img = de && (x >= IMG_X0) && (x < (IMG_X0 + IMG_W)) &&
                         (ya >= IMG_Y0) && (ya < (IMG_Y0 + IMG_H));
    wire [11:0] xr     = x - IMG_X0;                 // 图片内列号

    assign rf_rd   = (~in_img & ~pre & ~rf_empty) |
                     (in_img & xr[0] & pre & ~rf_empty);
    assign rgb_out = in_img ? (xr[0] ? hi : rf_dout[15:0]) : 16'd0;
    assign de_out  = de;

    always @(posedge pix_clk or posedge pix_rst) begin
        if (pix_rst) begin
            pre <= 1'b0;
            hi  <= 16'd0;
        end else begin
            if (vs)
                pre <= 1'b0;
            else if (!in_img && !pre && !rf_empty)
                pre <= 1'b1;

            if (in_img && !xr[0])
                hi <= rf_dout[31:16];
        end
    end

    // 写侧是否彻底排空：换 bank 之前必须等到这里，
    // 否则最后几个字会写进下一块缓冲（bn/bsend/wvld 在后面声明，故放在模块末尾）
    assign wr_idle = wf_empty & ~bsend & (bn == 3'd0) & ~wvld;

endmodule
