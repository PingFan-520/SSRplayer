// ============================================================================
//  tb_menu_fade.v —— 验证菜单淡入淡出（P25）
//
//  按键语义（见 osd_menu）：
//    KEY3(key_ok)   菜单外 -> 打开设置页(page0)；设置页第 0 项 -> 进 IMG 子菜单(page2)
//    KEY4(key_menu) 菜单内 -> 关闭；菜单外 -> 打开音乐列表(page1)
//
//  检查项：
//    1) 关闭时面板区域 alpha = 0
//    2) 打开：alpha 每帧 +1，0→8 不跳变，最后到 8
//    3) 进二级菜单：先淡出到 0、在"看不见"的时候换页，再淡入回 8
//    4) 关闭：alpha 每帧 -1，8→0，最后到 0
// ============================================================================
`timescale 1ns / 1ps

module tb_menu_fade;

    reg clk = 1'b0;
    always #13.3 clk = ~clk;          // 37.5MHz

    reg rst = 1'b1;
    reg [11:0] x = 12'd0, y = 12'd0;
    reg de = 1'b1;
    reg k_menu = 1'b0, k_up = 1'b0, k_down = 1'b0, k_ok = 1'b0;

    wire        osd_on;
    wire [23:0] osd_rgb;
    wire [3:0]  osd_alpha;
    wire        menu_open;
    wire [2:0]  dbg_item;
    wire [3:0]  dbg_val;
    wire        cfg_commit;
    wire [1:0]  cfg_trans;
    wire [3:0]  cfg_bright, cfg_contrast;
    wire [1:0]  cfg_scale;
    wire [2:0]  cfg_mus;
    wire        cfg_auto, cfg_meter, cfg_sub, cfg_style;
    wire [2:0]  cfg_hold;
    wire [3:0]  cfg_vol;
    wire        nav_next, nav_prev, page_mus;

    osd_menu #(
        .HACTIVE(1280), .VACTIVE(720),
        .PX0(340), .PY0(30), .PW(600), .PH(660)
    ) dut (
        .clk(clk), .rst(rst),
        .x(x), .y(y), .de(de),
        .key_menu(k_menu), .key_up(k_up), .key_down(k_down), .key_ok(k_ok),
        .mus_total(4'd4), .mus_name(64'd0), .alert(1'b0),
        .osd_on(osd_on), .osd_rgb(osd_rgb), .osd_alpha(osd_alpha),
        .menu_open(menu_open), .dbg_item(dbg_item), .dbg_val(dbg_val),
        .cfg_commit(cfg_commit),
        .cfg_trans(cfg_trans), .cfg_bright(cfg_bright), .cfg_contrast(cfg_contrast),
        .cfg_scale(cfg_scale), .cfg_mus(cfg_mus), .cfg_auto(cfg_auto),
        .nav_next(nav_next), .nav_prev(nav_prev), .page_mus(page_mus),
        .cfg_vol(cfg_vol), .cfg_meter(cfg_meter), .cfg_sub(cfg_sub),
        .cfg_hold(cfg_hold), .cfg_style(cfg_style)
    );

    integer f;
    integer a_prev;
    integer n_bad  = 0;
    integer n_zero = 0;
    integer pg_sw  = -1;
    integer sw_alpha = 9;

    task frame;
        begin
            x <= 12'd0; y <= 12'd0;
            @(posedge clk);
            x <= 12'd400; y <= 12'd300;
            repeat (6) @(posedge clk);
        end
    endtask

    task press_menu;  begin k_menu <= 1'b1; @(posedge clk); k_menu <= 1'b0; end endtask
    task press_ok;    begin k_ok   <= 1'b1; @(posedge clk); k_ok   <= 1'b0; end endtask
    task press_down;  begin k_down <= 1'b1; @(posedge clk); k_down <= 1'b0; end endtask
    task press_up;    begin k_up   <= 1'b1; @(posedge clk); k_up   <= 1'b0; end endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 1'b0;
        repeat (5) @(posedge clk);

        // ---------------- 1) 初始 ----------------
        frame;
        $display("[1] 关闭态 alpha=%0d on=%b", osd_alpha, osd_on);
        if (osd_alpha !== 4'd0 || osd_on !== 1'b0) begin
            $display("  [FAIL] 关闭时面板不该可见");
            n_bad = n_bad + 1;
        end

        // ---------------- 2) 打开设置页：淡入 ----------------
        $display("[2] KEY3 打开设置页：应逐帧 0->8");
        press_ok;
        a_prev = osd_alpha;
        for (f = 0; f < 12; f = f + 1) begin
            frame;
            $display("   f%0d page=%0d mfade=%0d alpha=%0d", f, dut.r_page, dut.mfade, osd_alpha);
            if (osd_alpha < a_prev || osd_alpha > a_prev + 1) begin
                $display("  [FAIL] 淡入不单调/跳变：%0d -> %0d", a_prev, osd_alpha);
                n_bad = n_bad + 1;
            end
            a_prev = osd_alpha;
        end
        if (osd_alpha !== 4'd8) begin
            $display("  [FAIL] 淡入没到 8（%0d）", osd_alpha);
            n_bad = n_bad + 1;
        end

        // ---------------- 2.5) 上下键：高亮条必须跟着动 ----------------
        $display("[2.5] KEY2 下移：r_item 应逐帧跟随（高亮条不动那个 bug 的回归点）");
        press_down;
        repeat (3) frame;
        $display("   item=%0d r_item=%0d mfade=%0d", dut.item, dut.r_item, dut.mfade);
        if (dut.r_item !== 3'd1) begin
            $display("  [FAIL] 下键后高亮行没跟着动（r_item=%0d，应为 1）", dut.r_item);
            n_bad = n_bad + 1;
        end
        press_down;
        repeat (3) frame;
        if (dut.r_item !== 3'd2) begin
            $display("  [FAIL] 第二次下键高亮行没动（r_item=%0d，应为 2）", dut.r_item);
            n_bad = n_bad + 1;
        end
        press_up;
        repeat (3) frame;
        if (dut.r_item !== 3'd1) begin
            $display("  [FAIL] 上键后高亮行没回（r_item=%0d，应为 1）", dut.r_item);
            n_bad = n_bad + 1;
        end
        // 回到第 0 项（IMG），后面要进子菜单
        press_up;
        repeat (3) frame;
        if (dut.r_item !== 3'd0) begin
            $display("  [FAIL] 没回到第 0 项（r_item=%0d）", dut.r_item);
            n_bad = n_bad + 1;
        end

        // ---------------- 3) 进 IMG 子菜单：先淡出再淡入 ----------------
        $display("[3] KEY3 进 IMG 子菜单：应先淡到 0 再换页再淡入");
        press_ok;
        a_prev = osd_alpha;
        for (f = 0; f < 26; f = f + 1) begin
            frame;
            if (dut.r_page == 2'd2 && pg_sw < 0) begin
                pg_sw    = f;
                sw_alpha = osd_alpha;
            end
            if (osd_alpha == 4'd0) n_zero = n_zero + 1;
            $display("   f%0d page=%0d mfade=%0d alpha=%0d", f, dut.r_page, dut.mfade, osd_alpha);
            if ((osd_alpha > a_prev + 1) || (osd_alpha + 1 < a_prev)) begin
                $display("  [FAIL] 换页淡变跳变：%0d -> %0d", a_prev, osd_alpha);
                n_bad = n_bad + 1;
            end
            a_prev = osd_alpha;
        end
        $display("   换页在第 %0d 帧，那帧 alpha=%0d，中间 alpha==0 帧数=%0d",
                 pg_sw, sw_alpha, n_zero);
        if (dut.r_page !== 2'd2) begin
            $display("  [FAIL] 没进到 IMG 子菜单页（r_page=%0d）", dut.r_page);
            n_bad = n_bad + 1;
        end
        if (sw_alpha > 1) begin
            $display("  [FAIL] 换页时画面还亮着（alpha=%0d）", sw_alpha);
            n_bad = n_bad + 1;
        end
        if (osd_alpha !== 4'd8) begin
            $display("  [FAIL] 换页后没淡回 8（%0d）", osd_alpha);
            n_bad = n_bad + 1;
        end

        // ---------------- 4) KEY4 关闭：淡出 ----------------
        $display("[4] KEY4 关闭：应逐帧 8->0");
        press_menu;
        a_prev = osd_alpha;
        for (f = 0; f < 12; f = f + 1) begin
            frame;
            $display("   f%0d open=%b mfade=%0d alpha=%0d", f, menu_open, dut.mfade, osd_alpha);
            if (osd_alpha > a_prev || osd_alpha + 1 < a_prev) begin
                $display("  [FAIL] 淡出不单调/跳变：%0d -> %0d", a_prev, osd_alpha);
                n_bad = n_bad + 1;
            end
            a_prev = osd_alpha;
        end
        if (osd_alpha !== 4'd0) begin
            $display("  [FAIL] 淡出没到 0（%0d）", osd_alpha);
            n_bad = n_bad + 1;
        end

        if (n_bad == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL (%0d)", n_bad);
        $finish;
    end

endmodule
