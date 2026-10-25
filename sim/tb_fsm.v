// ============================================================================
//  tb_fsm.v —— 轮播状态机单元测试
//  ⚠ 本文件由 tools/gen_fsm_tb.py 从 rtl/top_board.v 自动抽取生成，不要手改；
//     改了 top_board 的状态机后重新跑一次脚本即可。
//
//  覆盖场景（都是上板真实踩过的坑）：
//    1. 清屏完成给 1 拍脉冲，而写 FIFO 要多等 800 拍才排空
//       —— 曾经写成 "clr_done && wr_idle" 直接死锁（数码管 03、黑屏）
//    2. 每次读图需要 20000 拍才给 done
//    3. 完整轮播 8 张，每张都走 CLEAR->ARM->LOAD->SHOW
// ============================================================================
`timescale 1ns / 1ps

module tb_fsm;

    reg clk = 1'b0;
    wire clk_pix = clk;                 // 与 top_board 内部同名
    reg rst_n = 1'b0;
    always #13.3 clk = ~clk;            // 37.5MHz

    parameter integer HOLD_FRM = 3;     // 让轮播快速走完整轮
    parameter integer IMG_NUM  = 8;
    parameter integer IMG_Y0   = 120;
    parameter integer USE_DBL  = 1;      // 与 top_board 一致（0=单缓冲）
    parameter integer V_OFF    = 25;

    // ---- 激励 ----
    reg sd_ready    = 1'b0;
    reg sc_clr_done = 1'b0;
    reg wr_idle_p   = 1'b1;
    reg rdr_done_p  = 1'b0;
    reg in_img_row  = 1'b0;
    reg frame_top   = 1'b0;

    localparam [2:0] LD_WAIT  = 3'd0,
                     LD_CLEAR = 3'd1,     // 把整个图片区写黑（缩放后留边不会残留上一张）
                     LD_ARM   = 3'd2,     // 换图后先让 img_idx 稳定
                     LD_LOAD  = 3'd3,
                     LD_FADE_OUT = 3'd5,  // 淡出到黑
                     LD_FADE_IN  = 3'd6,  // 从黑淡入新图（换 bank 在两者之间完成）
                     LD_WIPE     = 3'd7,  // 擦除/推入（按 rd_wipe 分界选 bank）
                     LD_SHOW  = 3'd4;

    reg        rd_en;
    reg        sc_clr;
    reg        load_mode;
    reg        rd_bank, wr_bank;
    reg        rd_bank_new;
    reg  [19:0] rd_wipe;
    reg        img_changed;
    reg  [1:0] dbg_effect = 2'd0;   // 0=FADE -> 走淡出/淡入
    reg  [1:0] dbg_scale  = 2'd0;   // 缩放模式（FSM 里做变化检测）
    reg        dbg_auto   = 1'b1;   // 自动轮播
    reg        nav_next   = 1'b0;   // KEY1 手动下一张
    reg        nav_prev   = 1'b0;   // KEY2 手动上一张
    reg  [7:0] fade_lvl;
    reg  [7:0] img_idx;

    reg [2:0]  ld_st;
    reg [12:0] fin_dly;
    reg [15:0] hold_frm;
    reg        clr_ok;          // 清屏完成标志（clr_done 只有 1 拍，必须锁存）
    reg [25:0] clr_wdog;        // 清屏看门狗（26 位 = 1.8s）
    reg [27:0] ld_wdog;         // 加载看门狗（28 位 = 7.1s，720p 一张约 0.88s）
    reg  [1:0]  scale_d;            // 上一次加载用的缩放模式（变了就重载当前图）
    reg         wipe_dir;           // 0 = SLIDE 新图从下往上推；1 = WIPE 新图从上往下覆盖
    reg  [3:0]  wipe_frm;           // 已走的帧数（兼作看门狗）
    reg         first_img;          // 1 = 上电首张（不做转场）

    integer shown_cnt;
    initial shown_cnt = 0;

    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) begin
            ld_st     <= LD_WAIT;
            img_idx   <= 8'd0;
            rd_en     <= 1'b0;
            sc_clr    <= 1'b0;
            clr_ok    <= 1'b0;
            clr_wdog  <= 24'd0;
            ld_wdog   <= 28'd0;
            load_mode <= 1'b1;          // 只有首次为 1：此时读停、整帧写 A
            rd_bank   <= 1'b0;
            wr_bank   <= 1'b0;
            rd_bank_new <= 1'b0;
            rd_wipe   <= 20'd153600;
            wipe_dir  <= 1'b0;
            wipe_frm  <= 4'd0;
            fade_lvl  <= 8'd255;
            img_changed <= 1'b0;
            scale_d   <= 2'd0;
            first_img <= 1'b1;
            fin_dly   <= 13'd0;
            hold_frm  <= 16'd0;
        end else begin
            if (ld_st != LD_LOAD) img_changed <= 1'b0;

            case (ld_st)
                LD_WAIT: begin
                    if (sd_ready) begin
                        sc_clr   <= 1'b1;     // 先清屏，再开始读图
                        clr_ok   <= 1'b0;
                        clr_wdog <= 26'd0;
                        fin_dly  <= 13'd0;
                        ld_st    <= LD_CLEAR;
                    end
                end

                // 清屏：把 640x480 框整块写 0，避免缩放留边处露出上一张的内容。
                // 153600 字，只在写窗口里跑，约 57ms（首张 load_mode=1 时约 20ms）。
                LD_CLEAR: begin
                    sc_clr <= 1'b0;
                    // 清屏结束还要等写 FIFO 排空：清屏最后那 256 个字可能正卡在
                    // 写窗口外。FIFO 满着就开读的话，刚开始的像素会被丢掉。
                    //
                    // 关键：clr_done 是**1 拍脉冲**，而它出现时 FIFO 里还有几百个字
                    // （wr_idle 还是 0）。直接写 "clr_done && wr_idle" 会漏掉那唯一
                    // 1 拍 -> 永久停在 CLEAR（上板实测：黑屏 + 数码管 03）。
                    // 所以先把完成标志锁存下来。
                    if (sc_clr_done) clr_ok <= 1'b1;

                    if (!wr_idle_p) clr_wdog <= clr_wdog + 26'd1;

                    if ((clr_ok && wr_idle_p) || (clr_wdog == 26'h3FFFFFF)) begin
                        fin_dly  <= 13'd0;
                        clr_ok   <= 1'b0;
                        clr_wdog <= 26'd0;
                        ld_st    <= LD_ARM;
                    end
                end

                // img_idx 是像素域的寄存器，SD 域要用它算起始扇区，
                // 换图后先等 16 拍（~427ns，远大于 2 个 25MHz 周期）再发请求，
                // 避免多比特总线正在变化时被采样。
                LD_ARM: begin
                    if (fin_dly == 13'd16) begin
                        rd_en    <= 1'b1;
                        ld_wdog  <= 28'd0;
                        fin_dly  <= 13'd0;
                        ld_st    <= LD_LOAD;
                    end else begin
                        fin_dly <= fin_dly + 13'd1;
                    end
                end

                LD_LOAD: begin
                    if (!USE_DBL[0]) load_mode <= 1'b1;   // 单缓冲：整帧只写不读
                    // 注意：这里不再拉高 load_mode。首次之后 load_mode 恒 0，
                    // 读写靠"图片行 vs 非图片行"在时间上分离，读侧永不中断。
                    //
                    // 换 bank 的条件：SD 读完 + 写侧彻底排空 + 64 拍余量。
                    // 只等固定 4000 拍是不够的：最后一批像素可能正卡在写窗口外，
                    // 窗口最坏 21ms 才开，提前换 bank 会把尾巴写进下一块缓冲。
                    // 再要求"当前不在图片行"：换 bank 只在消隐期发生，
                    // 否则这一帧会上面旧图、下面新图（看起来像两张图拼接）
                    // 加载超时保护：SD 万一读不完（坏块/接触不良），
                    // 3 秒后强制收工，至少把已经写进去的部分显示出来，
                    // 而不是永远卡在 LOAD（黑屏）。
                    if (!rdr_done_p) ld_wdog <= ld_wdog + 28'd1;

                    if ((rdr_done_p && wr_idle_p && !in_img_row) ||
                        (ld_wdog == 28'hFFFFFFF)) begin
                        if (fin_dly == 13'd64) begin
                            rd_en     <= 1'b0;   // 撤请求，让 reader 清 done
                            ld_wdog   <= 28'd0;
                            load_mode <= 1'b0;
                            hold_frm  <= 16'd0;
                            // 转场：按菜单里选的特效分四种
                            //   FADE(0)  淡出到黑 -> 换 bank（看不见）-> 淡入
                            //   SLIDE(1) 新图从下往上推入（分界 153600 -> 0）
                            //   WIPE(2)  新图从上往下覆盖（分界 0 -> 153600）
                            //   CUT(3)   硬切
                            // 交叉淡化要同时读新旧两个地址，单读口带宽不够，
                            // 所以 FADE 走"中间经过全黑"的经典做法；
                            // SLIDE/WIPE 复用 frame_buffer 的 rd_wipe 分界选 bank。
                            if (first_img || !USE_DBL[0]) begin
                                // 上电首张：直接硬切，不做任何转场
                                // （正常上电就该立刻出图，而不是先黑一下再淡入）
                                first_img   <= 1'b0;
                                rd_bank     <= USE_DBL[0] ? wr_bank : 1'b0;
                                wr_bank     <= USE_DBL[0] ? ~wr_bank : 1'b0;
                                rd_bank_new <= USE_DBL[0] ? wr_bank : 1'b0;
                                rd_wipe     <= 20'd153600;
                                fade_lvl    <= 8'd255;
                                ld_st       <= LD_SHOW;
                            end else if (!USE_DBL[0]) begin
                                // 单缓冲：没有第二块可读，只能硬切
                                rd_bank     <= 1'b0;
                                wr_bank     <= 1'b0;
                                rd_bank_new <= 1'b0;
                                rd_wipe     <= 20'd153600;
                                fade_lvl    <= 8'd255;
                                ld_st       <= LD_SHOW;
                            end else begin
                                case (dbg_effect)
                                    2'd0: begin      // FADE
                                        fade_lvl <= 8'd255;
                                        rd_bank_new <= wr_bank;
                                        rd_wipe     <= 20'd153600;
                                        ld_st       <= LD_FADE_OUT;
                                    end
                                    2'd1: begin      // SLIDE：新图从下往上推
                                        rd_bank_new <= wr_bank;      // 新图
                                        rd_wipe     <= 20'd153600;   // 先全读旧图
                                        wipe_dir    <= 1'b0;
                                        wipe_frm    <= 4'd0;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_WIPE;
                                    end
                                    2'd2: begin      // WIPE：新图从上往下覆盖
                                        // 交换角色：rd_bank 放新图、rd_bank_new 放旧图，
                                        // 分界 0 -> 153600，上半部分逐帧变成新图。
                                        rd_bank_new <= rd_bank;      // 旧图
                                        rd_bank     <= wr_bank;      // 新图
                                        rd_wipe     <= 20'd0;
                                        wipe_dir    <= 1'b1;
                                        wipe_frm    <= 4'd0;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_WIPE;
                                    end
                                    default: begin   // CUT：硬切
                                        rd_bank     <= wr_bank;
                                        rd_bank_new <= wr_bank;
                                        rd_wipe     <= 20'd153600;
                                        wr_bank     <= ~wr_bank;
                                        fade_lvl    <= 8'd255;
                                        ld_st       <= LD_SHOW;
                                    end
                                endcase
                            end
                        end else begin
                            fin_dly <= fin_dly + 13'd1;
                        end
                    end
                end

                // 整幅推入：每帧把分界下移 15360 字（= 48 行），10 帧推完。
                // 分界必须整 4 字对齐（15360 / 320 都是 4 的倍数），
                // 这样 4 字 burst 绝不会跨 bank，控制器不会读到错位数据。
                // 淡出：每帧 -32，8 帧从 255 降到 0（约 0.27s）
                LD_FADE_OUT: begin
                    if (frame_top) begin
                        if (fade_lvl <= 8'd32) begin
                            fade_lvl <= 8'd0;              // 全黑
                            rd_bank  <= USE_DBL[0] ? wr_bank : 1'b0;
                            wr_bank  <= USE_DBL[0] ? ~wr_bank : 1'b0;
                            ld_st    <= LD_FADE_IN;        // 黑屏里换 bank，看不见
                        end else begin
                            fade_lvl <= fade_lvl - 8'd32;
                        end
                    end
                end

                // 淡入新图：每帧 +32，8 帧回到 255
                LD_FADE_IN: begin
                    if (frame_top) begin
                        if (fade_lvl >= 8'd224) begin
                            fade_lvl <= 8'd255;
                            hold_frm <= 16'd0;
                            ld_st    <= LD_SHOW;
                        end else begin
                            fade_lvl <= fade_lvl + 8'd32;
                        end
                    end
                end

                // ------------------------------------------------------------------
                // 擦除/推入转场：每帧把分界挪 15360 字（= 48 行），11 帧走完。
                //   分界恒 4 字对齐（153600 / 15360 / 320 都能被 4 整除），
                //   4 字 burst 绝不会跨 bank。
                //   wipe_dir=0（SLIDE）：153600 -> 0，新图从下往上推入；
                //   wipe_dir=1（WIPE） ：0 -> 153600，新图从上往下覆盖。
                //   只在 frame_top 改分界（此时 rd_cnt 正在归零），不会半帧撕裂。
                // ------------------------------------------------------------------
                LD_WIPE: begin
                    if (frame_top) begin
                        if (wipe_frm >= 4'd13) begin
                            // 看门狗：无论什么情况，13 帧内必定收尾，不会卡死
                            rd_wipe     <= 20'd153600;
                            rd_bank     <= wipe_dir ? rd_bank : rd_bank_new;
                            rd_bank_new <= wipe_dir ? rd_bank : rd_bank_new;
                            wr_bank     <= ~(wipe_dir ? rd_bank : rd_bank_new);
                            wipe_frm    <= 4'd0;
                            hold_frm    <= 16'd0;
                            ld_st       <= LD_SHOW;
                        end else begin
                            wipe_frm <= wipe_frm + 4'd1;
                            if (!wipe_dir) begin
                                if (rd_wipe == 20'd0) begin
                                    // 已经整幅是新图，下一帧正式切换
                                    rd_bank     <= rd_bank_new;
                                    rd_bank_new <= rd_bank_new;
                                    wr_bank     <= ~rd_bank_new;
                                    wipe_frm    <= 4'd0;
                                    hold_frm    <= 16'd0;
                                    ld_st       <= LD_SHOW;
                                end else if (rd_wipe <= 20'd15360) begin
                                    rd_wipe <= 20'd0;
                                end else begin
                                    rd_wipe <= rd_wipe - 20'd15360;
                                end
                            end else begin
                                if (rd_wipe >= 20'd153600) begin
                                    rd_bank     <= rd_bank;      // WIPE 里 rd_bank 已经是新图
                                    rd_bank_new <= rd_bank;
                                    wr_bank     <= ~rd_bank;
                                    rd_wipe     <= 20'd153600;
                                    wipe_frm    <= 4'd0;
                                    hold_frm    <= 16'd0;
                                    ld_st       <= LD_SHOW;
                                end else if (rd_wipe >= 20'd138240) begin
                                    rd_wipe <= 20'd153600;
                                end else begin
                                    rd_wipe <= rd_wipe + 20'd15360;
                                end
                            end
                        end
                    end
                end

                LD_SHOW: begin
                    if (fade_lvl != 8'd255) fade_lvl <= 8'd255;
                    // 正常显示期间强制"不分界"：任何残留的 rd_wipe/rd_bank_new
                    // 都会让下半帧从另一块 bank 取数（那正是"横缝 + 下半重复"的成因）
                    rd_wipe     <= 20'd153600;
                    rd_bank_new <= rd_bank;
                    // 手动切图（KEY1/KEY2）优先；自动轮播要菜单里开着才走
                    if (frame_top && dbg_auto) hold_frm <= hold_frm + 16'd1;

                    // 菜单“缩放”只在加载阶段生效，光改档位看不出变化。
                    // 这里检测到档位变化就重载当前这张（约 0.5s 后就能看到新效果），
                    // 否则用户会以为缩放坏了（上板反馈过“缩放无法使用”）。
                    if (dbg_scale != scale_d) begin
                        scale_d   <= dbg_scale;
                        if (USE_DBL[0] && (wr_bank == rd_bank)) wr_bank <= ~rd_bank;
                        sc_clr    <= 1'b1;
                        clr_ok    <= 1'b0;
                        clr_wdog  <= 26'd0;
                        fin_dly   <= 13'd0;
                        hold_frm  <= 16'd0;
                        ld_st     <= LD_CLEAR;
                    end else if (nav_next || nav_prev ||
                                 (dbg_auto && (hold_frm >= HOLD_FRM[15:0]))) begin
                        // 下一张 / 上一张 / 自动轮播到点
                        if (nav_prev)
                            img_idx <= (img_idx == 8'd0) ? (IMG_NUM[7:0] - 8'd1)
                                                         : (img_idx - 8'd1);
                        else
                            img_idx <= (img_idx >= IMG_NUM[7:0] - 8'd1) ? 8'd0
                                                                        : (img_idx + 8'd1);
                        scale_d   <= dbg_scale;
                        // 安全护栏：加载前必须保证"写的那块 != 正在显示的那块"，
                        // 否则清屏会把用户正在看的图画黑（上板见过"半帧撕裂再黑屏"）。
                        if (USE_DBL[0] && (wr_bank == rd_bank)) wr_bank <= ~rd_bank;
                        sc_clr    <= 1'b1;
                        clr_ok    <= 1'b0;
                        clr_wdog  <= 26'd0;
                        fin_dly   <= 13'd0;
                        ld_st     <= LD_CLEAR;
                    end
                end

                default: ld_st <= LD_WAIT;
            endcase
        end
    end


    // ---- 各状态停留拍数 ----
    reg [2:0] prev_st;
    initial prev_st = 3'd0;
    integer n_wait = 0, n_clear = 0, n_arm = 0, n_load = 0, n_show = 0, clr_cnt = 0;
    integer n_wipe = 0, wipe_cnt = 0;
    always @(posedge clk) begin
        case (ld_st)
          3'd0: n_wait  = n_wait + 1;
          3'd1: begin n_clear = n_clear + 1; if (n_clear == 1 || ld_st != prev_st) clr_cnt = clr_cnt + 1; end
          3'd2: n_arm   = n_arm + 1;
          3'd3: n_load  = n_load + 1;
          3'd4: begin n_show = n_show + 1; shown_cnt = shown_cnt + 1; end
          3'd5, 3'd6, 3'd7: begin
              n_wipe = n_wipe + 1;
              if (ld_st != prev_st) wipe_cnt = wipe_cnt + 1;
          end
        endcase
    end

    // ---- 模拟清屏：3000 拍，clr_done 只有 1 拍，之后 800 拍才排空 ----
    initial begin
        forever begin
            @(posedge clk);
            if (sc_clr) begin
                wr_idle_p = 1'b0;
                repeat (3000) @(negedge clk);
                @(negedge clk) sc_clr_done = 1'b1;
                @(negedge clk) sc_clr_done = 1'b0;
                repeat (800) @(negedge clk);
                wr_idle_p = 1'b1;
            end
        end
    end

    // ---- 模拟读图：20000 拍后给 done ----
    initial begin
        forever begin
            @(posedge clk);
            if (rd_en && !rdr_done_p) begin
                repeat (20000) @(negedge clk);
                rdr_done_p = 1'b1;
            end
        end
    end
    always @(negedge clk) if (!rd_en) rdr_done_p <= 1'b0;

    // ---- 模拟：在 SHOW 刚开始那一刻改缩放档位，FSM 应当在 1 帧内重载 ----
    //   HOLD_FRM=3 时，正常轮播要 3 帧后才进 CLEAR；
    //   若在 hold_frm==0 时改档位、而 CLEAR 却在 1 帧内出现，说明重载生效。
    integer tick_cnt = 0, st_change = -1, st_clear = -1;
    always @(posedge clk) begin
        tick_cnt = tick_cnt + 1;
        if (st_change < 0 && (tick_cnt > 800000) && (ld_st == 3'd4) && (hold_frm == 16'd0)) begin
            dbg_scale = 2'd1;
            st_change = tick_cnt;
        end
        if (st_change > 0 && st_clear < 0 && (ld_st == 3'd1)) st_clear = tick_cnt;
    end

    // ---- 模拟：把特效切成 SLIDE(1)，验证 LD_WIPE 能进能出 ----
    //   每帧挪 15360 字（48 行），11 步 + 收尾 ≈ 12 帧。
    integer tick2 = 0, wipe_in = -1, wipe_out = -1;
    always @(posedge clk) begin
        if (st_change > 0) tick2 = tick2 + 1;
        if (st_change > 0 && tick2 == 600000) dbg_effect = 2'd1;
        if (dbg_effect == 2'd1 && wipe_in  < 0 && (ld_st == 3'd7)) wipe_in  = tick_cnt;
        if (wipe_in > 0 && wipe_out < 0 && (ld_st == 3'd4))          wipe_out = tick_cnt;
    end

    // ---- 模拟帧同步 ----
    initial begin
        forever begin
            repeat (20000) @(negedge clk);
            frame_top = 1'b1;
            @(negedge clk);
            frame_top = 1'b0;
        end
    end

    // ---- 观察 ----
    always @(posedge clk) begin
        if (ld_st !== prev_st) begin
            $display("  ld_st %0d -> %0d (img=%0d rd_en=%0d clr=%0d)",
                     prev_st, ld_st, img_idx, rd_en, sc_clr);
            prev_st <= ld_st;
        end
    end

    initial begin
        repeat (50) @(negedge clk);
        rst_n = 1'b1;
        repeat (100) @(negedge clk);
        sd_ready = 1'b1;

        repeat (6000000) @(negedge clk);
        $display("[fsm] 停留拍数 WAIT=%0d CLEAR=%0d ARM=%0d LOAD=%0d SHOW=%0d",
                 n_wait, n_clear, n_arm, n_load, n_show);
        if (clr_cnt == 0) clr_cnt = 1;
        $display("[fsm] 清屏 %0d 次，平均 %0d 拍/次（期望约 3803）", clr_cnt, n_clear/clr_cnt);
        $display("[fsm] 淡出+淡入 %0d 次，平均 %0d 拍/次（期望约 18 帧 = 360000 拍）",
                 wipe_cnt, (wipe_cnt==0) ? 0 : n_wipe/wipe_cnt);
        if (st_change < 0) begin
            $display("[FAIL] 测试没触发缩放档位变化（激励没跑到）");
        end else if (st_clear < 0) begin
            $display("[FAIL] 改缩放档位后 FSM 没有重载（一直不进 CLEAR）");
        end else if ((st_clear - st_change) > 20000) begin
            $display("[FAIL] 改档位后 %0d 拍才重载，超过 1 帧（应 < 20000）",
                     st_clear - st_change);
        end else
            $display("[ok] 改缩放档位后 %0d 拍触发重载", st_clear - st_change);

        if (wipe_in < 0) begin
            $display("[FAIL] 特效切 SLIDE 后没进 LD_WIPE");
        end else if (wipe_out < 0) begin
            $display("[FAIL] LD_WIPE 卡住没回到 SHOW");
        end else if ((wipe_out - wipe_in) > 400000) begin
            $display("[FAIL] LD_WIPE 用了 %0d 拍（>20 帧），可能走看门狗",
                     wipe_out - wipe_in);
        end else
            $display("[ok] SLIDE 擦除转场 %0d 拍完成（约 %0d 帧）",
                     wipe_out - wipe_in, (wipe_out - wipe_in) / 20000);

        if ((n_clear/clr_cnt) > 6000) begin
            $display("[FAIL] CLEAR 平均 %0d 拍，疑似死锁/走看门狗", n_clear/clr_cnt);
        end else if (n_show < 100000) begin
            $display("[FAIL] 没稳定进入 SHOW");
        end else if (clr_cnt < 8) begin
            $display("[FAIL] 没走完整轮（只清了 %0d 次，至少要 8 次）", clr_cnt);
        end else begin
            $display("[PASS] 状态机流程正常：清屏 %0d 次、进入 SHOW %0d 拍",
                     clr_cnt, n_show);
        end
        $finish;
    end

endmodule
