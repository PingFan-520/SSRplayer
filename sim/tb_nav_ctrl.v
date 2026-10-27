`timescale 1ns / 1ps
// ============================================================================
//  tb_nav_ctrl.v —— 切图决策单元测试
//
//  针对上板反馈的三个现象逐条验证：
//    1) 轮播 OFF 却自己切图
//    2) 轮播 OFF 时改"切屏间隔"就开始切图
//    3) 非菜单态按 KEY1/KEY2 不切图（按键落在加载/转场里被吃掉）
//  另外验证 AUTO 打开后按档位计时、改档位重新计时。
// ============================================================================
module tb_nav_ctrl;

    reg clk = 1'b0;
    always #13 clk = ~clk;              // ~37MHz，与 clk_pix 同量级

    reg        rst = 1'b1;
    reg        frame_tick = 1'b0;
    reg        showing    = 1'b0;
    reg        auto_en    = 1'b0;
    reg  [2:0] hold_sel   = 3'd1;
    reg        key_next   = 1'b0;
    reg        key_prev   = 1'b0;
    wire       step, step_prev;
    wire [15:0] hold_cnt;

    nav_ctrl u_dut (
        .clk(clk), .rst(rst),
        .frame_tick(frame_tick), .showing(showing),
        .auto_en(auto_en), .hold_sel(hold_sel),
        .key_next(key_next), .key_prev(key_prev),
        .step(step), .step_prev(step_prev), .hold_cnt(hold_cnt)
    );

    integer n_fail = 0;
    integer n_step = 0;                 // 累计 step 次数
    integer last_dir = -1;

    always @(posedge clk) begin
        if (!rst && step) begin
            n_step   = n_step + 1;
            last_dir = step_prev;
        end
    end

    task chk;
        input [255:0] name;
        input integer got;
        input integer exp;
        begin
            if (got !== exp) begin
                $display("[FAIL] %0s: got %0d exp %0d", name, got, exp);
                n_fail = n_fail + 1;
            end else
                $display("[ ok ] %0s = %0d", name, got);
        end
    endtask

    // 走 n 帧（每帧 1 个 frame_tick）
    task frames;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(posedge clk); frame_tick <= 1'b1;
                @(posedge clk); frame_tick <= 1'b0;
                @(posedge clk);
            end
        end
    endtask

    // 按下 -> 撤键 -> 等 step 落地（pend 1 拍 + step 1 拍 + 观测 2 拍，留足 8 拍）
    task press_next;
        begin
            @(posedge clk); key_next <= 1'b1;
            @(posedge clk); key_next <= 1'b0;
            repeat (8) @(posedge clk);
        end
    endtask

    task press_prev;
        begin
            @(posedge clk); key_prev <= 1'b1;
            @(posedge clk); key_prev <= 1'b0;
            repeat (8) @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (2) @(posedge clk);

        // ------------------------------------------------------------------
        // 1) 轮播 OFF：显示 600 帧（远超最大档 900? 用 600 < 900 但 > 90/150/240/450）
        //    这里用 600 帧覆盖 3S/5S/8S/15S 四档，加一次改档位
        // ------------------------------------------------------------------
        $display("---- 1) autoplay OFF: must never step ----");
        showing  <= 1'b1;
        auto_en  <= 1'b0;
        hold_sel <= 3'd0;                  // 3s 档
        n_step = 0;
        frames(200);
        chk("off_steps_3s", n_step, 0);
        hold_sel <= 3'd1;                  // 改档位：5s
        frames(200);
        chk("off_steps_after_hold_change", n_step, 0);
        hold_sel <= 3'd4;                  // 改到 30s（阈值最大）
        frames(300);
        chk("off_steps_30s", n_step, 0);
        chk("hold_cnt_forced_0", hold_cnt, 0);

        // ------------------------------------------------------------------
        // 2) AUTO 打开，5s 档（150 帧）：到点切一次，方向=下一张
        // ------------------------------------------------------------------
        $display("---- 2) autoplay ON, 150 frames ----");
        hold_sel <= 3'd1;
        auto_en  <= 1'b1;
        n_step = 0; last_dir = -1;
        frames(149);
        chk("on_steps_before", n_step, 0);
        frames(4);
        chk("on_steps_at_150", n_step, 1);
        chk("on_dir_next", last_dir, 0);

        // 切完之后重新计时：再 150 帧应再切一次
        frames(140);
        chk("reload_no_early", n_step, 1);
        frames(20);
        chk("reload_second", n_step, 2);

        // ------------------------------------------------------------------
        // 3) 计数到一半改档位：必须重新计时，不能"接着算"
        //    （上板现象：改间隔就立刻切）
        // ------------------------------------------------------------------
        $display("---- 3) change hold mid-count ----");
        n_step = 0;
        frames(100);                       // 计到 100/150
        hold_sel <= 3'd2;                  // 改成 8s = 240 帧
        frames(150);                       // 150 < 240，不应切
        chk("mid_change_no_step", n_step, 0);
        frames(95);                        // 累计 245 > 240
        chk("mid_change_then_step", n_step, 1);

        // ------------------------------------------------------------------
        // 4) 关掉 AUTO：计数清零，不再切
        // ------------------------------------------------------------------
        $display("---- 4) turn OFF again ----");
        auto_en <= 1'b0;
        frames(5);
        chk("off_hold_cnt", hold_cnt, 0);
        n_step = 0;
        frames(300);
        chk("off_no_step", n_step, 0);

        // ------------------------------------------------------------------
        // 5) 手动：显示中按下，立刻切一次，方向正确
        // ------------------------------------------------------------------
        $display("---- 5) manual while showing ----");
        n_step = 0; last_dir = -1;
        press_next;
        chk("man_next_steps", n_step, 1);
        chk("man_next_dir",  last_dir, 0);
        press_prev;
        chk("man_prev_steps", n_step, 2);
        chk("man_prev_dir",   last_dir, 1);

        // ------------------------------------------------------------------
        // 6) 手动：加载/转场期间按下（showing=0）不能丢
        //    挂起 -> showing 一回来就执行，且只执行一次
        // ------------------------------------------------------------------
        $display("---- 6) manual while loading (showing=0) ----");
        showing <= 1'b0;
        n_step = 0; last_dir = -1;
        press_prev;
        frames(20);
        chk("pend_waits", n_step, 0);
        showing <= 1'b1;
        frames(3);
        chk("pend_exec", n_step, 1);
        chk("pend_dir",  last_dir, 1);
        frames(20);
        chk("pend_no_repeat", n_step, 1);

        // 连按两次只算一次（挂起是"有/无"，避免加载期间误连击滚过很多张）
        showing <= 1'b0;
        n_step = 0;
        press_next;
        press_next;
        frames(5);
        showing <= 1'b1;
        frames(3);
        chk("pend_collapse", n_step, 1);

        // ------------------------------------------------------------------
        // 7) 手动比自动优先：两者同一拍满足时，方向取手动
        // ------------------------------------------------------------------
        $display("---- 7) manual wins over auto ----");
        auto_en  <= 1'b1;
        hold_sel <= 3'd0;                  // 90 帧
        n_step = 0; last_dir = -1;
        frames(89);
        showing <= 1'b0;
        press_prev;                        // 挂起"上一张"
        showing <= 1'b1;
        frames(3);                         // 此时计数也已到点
        chk("prio_steps", n_step, 1);
        chk("prio_dir_prev", last_dir, 1);

        if (n_fail == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL (%0d)", n_fail);
        $finish;
    end

endmodule
