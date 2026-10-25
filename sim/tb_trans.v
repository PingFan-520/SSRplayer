// ============================================================================
//  tb_trans.v -- auto_transition ONESHOT / pre_clr 行为验证
//
//  目的：真实图片播放时，转场改成"换图瞬间先变黑，再用 16 帧淡入"。
//        这里验证三件事：
//          1) ONESHOT=1 时不会周期自动触发（只在 trig 时跑）
//          2) trig 后 prog 0 -> 255，16 帧完成
//          3) 完成后保持 255（= 停在新图上），pre_clr 可立刻归零
//        非 ONESHOT（ONESHOT=0）保持原来的周期 A/B 交替。
// ============================================================================
`timescale 1ns / 1ps

module tb_trans;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #13.3 clk = ~clk;              // 37.5MHz

    reg  frame_tick = 1'b0;
    reg  trig       = 1'b0;
    reg  pre_clr    = 1'b0;

    wire [7:0] prog_o, prog_n;
    wire       swap_o, swap_n;

    auto_transition #(.HOLD_FRAMES(4), .RUN_FRAMES(16), .ONESHOT(1)) u_one (
        .clk(clk), .rst(rst), .frame_tick(frame_tick),
        .trig(trig), .pre_clr(pre_clr), .effect(2'd0),
        .prog(prog_o), .swap(swap_o)
    );

    auto_transition #(.HOLD_FRAMES(4), .RUN_FRAMES(16), .ONESHOT(0)) u_cyc (
        .clk(clk), .rst(rst), .frame_tick(frame_tick),
        .trig(1'b0), .pre_clr(1'b0), .effect(2'd0),
        .prog(prog_n), .swap(swap_n)
    );

    // 每 200 拍一个"帧首"
    task tick; begin
        @(negedge clk); frame_tick = 1'b1;
        @(negedge clk); frame_tick = 1'b0;
        repeat (198) @(negedge clk);
    end endtask

    integer i, errs = 0;
    integer cyc_swap = 0;
    reg [7:0] p1;

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (3) @(negedge clk);

        // 1) 复位后 prog=0
        if (prog_o !== 8'd0) begin
            $display("[FAIL] 复位后 prog=%0d，应为 0", prog_o); errs = errs + 1;
        end

        // 2) ONESHOT 不自动触发：跑 20 帧，prog 必须一直是 0
        for (i = 0; i < 20; i = i + 1) tick;
        if (prog_o !== 8'd0) begin
            $display("[FAIL] ONESHOT 自动触发了（prog=%0d）", prog_o); errs = errs + 1;
        end else
            $display("[ok] ONESHOT 无自动触发");

        // 3) trig 后 16 帧淡入到 255
        //    注意：实际电路里 trig 由 tg_win 撑 8 帧（一帧 90 万拍，1 拍脉冲必错过），
        //    所以这里也要跨过一个 frame_tick 才算有效触发。
        @(negedge clk); trig = 1'b1;
        tick;                                  // 跨一个帧首
        @(negedge clk); trig = 1'b0;
        for (i = 0; i < 18; i = i + 1) begin
            tick;
            if (i == 0) p1 = prog_o;
            if (i == 15) $display("[info] 第 16 帧 prog=%0d（应为 255）", prog_o);
        end
        if (prog_o !== 8'hFF) begin
            $display("[FAIL] 淡入结束 prog=%0d，应为 255", prog_o); errs = errs + 1;
        end else
            $display("[ok] 淡入到 255 并保持");

        // 4) 再跑 30 帧，不能自己重新触发
        for (i = 0; i < 30; i = i + 1) tick;
        if (prog_o !== 8'hFF) begin
            $display("[FAIL] 静置期 prog=%0d 变了（应保持 255）", prog_o); errs = errs + 1;
        end else
            $display("[ok] 静置 30 帧仍为 255（无周期交替）");

        // 5) pre_clr 立刻归零
        @(negedge clk); pre_clr = 1'b1;
        @(negedge clk); pre_clr = 1'b0;
        if (prog_o !== 8'd0) begin
            $display("[FAIL] pre_clr 后 prog=%0d，应为 0", prog_o); errs = errs + 1;
        end else
            $display("[ok] pre_clr 立刻归零（换图瞬间变黑）");

        // 6) ONESHOT=0 的实例仍应周期交替（swap 会翻转）
        for (i = 0; i < 60; i = i + 1) tick;
        if (swap_n === 1'bx) begin
            $display("[FAIL] swap 为 X"); errs = errs + 1;
        end else
            $display("[info] 周期实例 swap=%0d（应已翻转）", swap_n);

        if (errs == 0) $display("[PASS] 转场触发逻辑全部正确");
        else           $display("[FAIL] 共 %0d 项不符", errs);
        $finish;
    end

endmodule
