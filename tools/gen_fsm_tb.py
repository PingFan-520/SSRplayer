#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_fsm_tb.py —— 从 rtl/top_board.v 抽取轮播状态机，生成 sim/tb_fsm.v

为什么这么做：
    状态机里有大量"脉冲 vs 电平"的握手（clr_done 是 1 拍脉冲、wr_idle 是电平）。
    上板踩过两次死锁（数码管 03 = 卡在 LD_CLEAR），这类问题必须仿真堵住。
    手写 TB 复制状态机会和 RTL 走偏，所以直接**从 RTL 抽取代码**生成 TB，
    保证测的就是真实逻辑。

用法：
    python tools/gen_fsm_tb.py
    sim\\run_fsm.bat
"""

import io
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def extract_fsm(src):
    """从 case (ld_st) 往前找最近的 always，再往后配平 begin/end"""
    k = src.index("case (ld_st)")
    i = src.rindex("    always @", 0, k)
    depth = 0
    j = i
    while True:
        nl = src.index("\n", j)
        line = src[j:nl]
        depth += len(re.findall(r"\bbegin\b", line)) - len(re.findall(r"\bend\b", line))
        j = nl + 1
        if depth <= 0:
            break
    return src[i:j]


def main():
    src = io.open(os.path.join(ROOT, "rtl", "top_board.v"), encoding="utf-8").read()

    m = re.search(r"    localparam \[2:0\] LD_WAIT.*?LD_SHOW\s*=\s*3'd4;", src, re.S)
    params = m.group(0)

    decls = []
    for pat in [r"    reg \[2:0\]  ld_st;", r"    reg \[12:0\] fin_dly;",
                r"    reg \[15:0\] hold_frm;", r"    reg        clr_ok;.*?\n",
                r"    reg \[25:0\] clr_wdog;.*?\n", r"    reg \[27:0\] ld_wdog;.*?\n"]:
        mm = re.search(pat, src)
        if mm:
            decls.append(mm.group(0).rstrip())

    fsm = extract_fsm(src)

    tb = TB_TEMPLATE
    tb = tb.replace("%(PARAMS)s", params)
    tb = tb.replace("%(DECLS)s", "\n".join(decls))
    tb = tb.replace("%(FSM)s", fsm)

    out = os.path.join(ROOT, "sim", "tb_fsm.v")
    io.open(out, "w", encoding="utf-8", newline="\n").write(tb)
    print("生成 %s" % out)
    print("  FSM %d 行 / 声明 %d 项 / 参数 %d 行"
          % (len(fsm.splitlines()), len(decls), len(params.splitlines())))


TB_TEMPLATE = r"""// ============================================================================
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

%(PARAMS)s

    reg        rd_en;
    reg        sc_clr;
    reg        load_mode;
    reg        rd_bank, wr_bank;
    reg        rd_bank_new;
    reg  [19:0] rd_wipe;
    reg        img_changed;
    reg  [1:0] dbg_effect;          // 0=FADE -> 走整幅推入
    reg  [7:0] img_idx;

%(DECLS)s

    integer shown_cnt;
    initial shown_cnt = 0;

%(FSM)s

    // ---- 各状态停留拍数 ----
    reg [2:0] prev_st;
    initial prev_st = 3'd0;
    integer n_wait = 0, n_clear = 0, n_arm = 0, n_load = 0, n_show = 0, clr_cnt = 0;
    always @(posedge clk) begin
        case (ld_st)
          3'd0: n_wait  = n_wait + 1;
          3'd1: begin n_clear = n_clear + 1; if (n_clear == 1 || ld_st != prev_st) clr_cnt = clr_cnt + 1; end
          3'd2: n_arm   = n_arm + 1;
          3'd3: n_load  = n_load + 1;
          3'd4: begin n_show = n_show + 1; shown_cnt = shown_cnt + 1; end
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
"""


if __name__ == "__main__":
    main()
