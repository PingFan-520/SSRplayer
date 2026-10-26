`timescale 1ns / 1ps
// ============================================================================
//  tb_sd_chain.v —— sd_arb + sd_bmp_reader 联调（这条链以前没被单独测过）
//
//  为什么需要它：
//    sd_arb 与"客户端自己数 256 字"的握手是这里最容易出错的地方：
//    仲裁器什么时候把 val 门控给谁、busy 什么时候给客户端看，
//    只要差一拍，客户端就会少收/多收字，进而卡在收数中途（= 上板黑屏）。
//
//  假 SD 控制器按 sd_read.v 的真实时序建模：
//    rd_start_en 上升沿 -> 150 拍后 busy=1（命令阶段）
//    -> 再 60 拍开始吐 256 个字，每 4 拍一个 val
//    -> 吐完保持 busy 13 拍（CRC 收尾）再落下
//
//  被测：
//    · B 通道（图片）连续读 8 个扇区，核对字节流与文件逐字节一致
//    · 同时 A 通道（音频）也抢总线读 4 个扇区，核对两份数据都没有串
// ============================================================================
module tb_sd_chain;

    localparam integer NBYTE = 512 * 64;     // 文件缓冲

    reg         clk = 1'b0;
    always #20 clk = ~clk;                   // 25MHz

    reg         rst_n = 1'b0;
    integer     errs = 0;
    integer     i;

    // ---------------- 文件内容 ----------------
    reg [7:0] mem [0:NBYTE-1];
    integer   fsize;

    // ---------------- 总线（sd_ctrl_top 侧）----------------
    wire        s_start, s_busy, s_val;
    wire [31:0] s_sec;
    wire [15:0] s_data;

    // ---------------- A 通道：音频模拟 ----------------
    reg         a_req = 1'b0;
    reg  [31:0] a_sec = 32'd0;
    wire        a_busy, a_val;
    wire [15:0] a_data;
    integer     a_got = 0;
    integer     a_bad = 0;
    integer     a_next = 0;                  // 下一个要请求的扇区序号（在 a_list 里）

    // 音频要读的 4 个扇区：16,17,18,19（故意和图片区不重叠）
    reg [31:0] a_base = 32'd16;
    always @(posedge clk) begin
        if (a_val) begin
            if (a_data !== {mem[(a_sec*512 + a_got*2) % NBYTE],
                            mem[(a_sec*512 + a_got*2 + 1) % NBYTE]})
                a_bad = a_bad + 1;
            a_got = a_got + 1;
        end
    end

    // ---------------- B 通道：图片读取器 ----------------
    wire        b_start, b_busy, b_val;
    wire [31:0] b_sec;
    wire [15:0] b_data;

    wire [7:0]  byte_data;
    wire        byte_valid;
    wire        rd_done;

    reg  [15:0] b_got = 0;                   // 已收字节（12 位装不下 4096）
    integer     b_bad = 0;

    sd_bmp_reader #(
        .SEC_BASE(0), .SEC_STRIDE(8), .SEC_NUM(8)
    ) u_bmp (
        .clk(clk), .rst(~rst_n),
        .rd_start_en(b_start), .rd_sec_addr(b_sec),
        .rd_busy(b_busy), .rd_val_en(b_val), .rd_val_data(b_data),
        .sd_init_done(1'b1),
        .enable(1'b1), .img_idx(8'd0),
        .fifo_used(9'd0),                    // 永远有空位
        .stop(1'b0),
        .busy(), .done(rd_done),
        .byte_data(byte_data), .byte_valid(byte_valid)
    );

    always @(posedge clk) begin
        if (byte_valid) begin
            if (byte_data !== mem[b_got % NBYTE]) begin
                if (b_bad < 5)
                    $display("[ERR] 图片字节 #%0d: 得到 %02h 期望 %02h",
                             b_got, byte_data, mem[b_got % NBYTE]);
                b_bad = b_bad + 1;
            end
            b_got = b_got + 1;
        end
    end

    // ---------------- 仲裁器 ----------------
    sd_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_req(a_req), .a_sec(a_sec),
        .a_busy(a_busy), .a_val(a_val), .a_data(a_data), .a_gnt(),
        .b_req(b_start), .b_sec(b_sec),
        .b_busy(b_busy), .b_val(b_val), .b_data(b_data), .b_gnt(),
        .s_start(s_start), .s_sec(s_sec),
        .s_busy(s_busy), .s_val(s_val), .s_data(s_data),
        .sd_init_done(1'b1)
    );

    // ---------------- 假 SD 控制器 ----------------
    reg [3:0]  f_st;
    integer    f_wait, f_cnt;
    reg [31:0] f_sec;

    assign s_busy = (f_st == 4'd2) || (f_st == 4'd3) || (f_st == 4'd4);  // 命令/锁地址阶段不算 busy
    assign s_val  = (f_st == 4'd3) && (f_wait == 3);   // 每 4 拍一个单拍 val
    assign s_data = {mem[(f_sec*512 + f_cnt*2) % NBYTE],
                     mem[(f_sec*512 + f_cnt*2 + 1) % NBYTE]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_st <= 4'd0; f_wait <= 0; f_cnt <= 0; f_sec <= 0;
        end else begin
            case (f_st)
                4'd0: if (s_start) begin f_st <= 4'd5; end      // 先等一拍再锁地址
                4'd5: begin f_sec <= s_sec; f_wait <= 0; f_st <= 4'd1; end
                4'd1: begin                      // 命令阶段
                    if (f_wait == 150) begin f_wait <= 0; f_st <= 4'd2; end
                    else f_wait <= f_wait + 1;
                end
                4'd2: begin                      // 数据头 -> 开始吐字
                    if (f_wait == 60) begin f_wait <= 0; f_cnt <= 0; f_st <= 4'd3; end
                    else f_wait <= f_wait + 1;
                end
                4'd3: begin                      // 256 个字，每 4 拍一个
                    if (f_cnt == 256) begin f_st <= 4'd4; end
                    else begin
                        if (f_wait == 3) begin f_wait <= 0; f_cnt <= f_cnt + 1; end
                        else f_wait <= f_wait + 1;
                    end
                end
                4'd4: begin                      // CRC 收尾（13 拍）后 busy 落下
                    if (f_wait == 13) begin f_wait <= 0; f_st <= 4'd0; end
                    else f_wait <= f_wait + 1;
                end
                default: f_st <= 4'd0;
            endcase
        end
    end

    // ---------------- 主流程 ----------------
    initial begin
        // 载入文件
        begin : load
            integer fd, n;
            fd = $fopen("wav_in.wav", "rb");
            if (fd == 0) begin
                $display("[FAIL] 打不开 wav_in.wav");
                $finish;
            end
            n = $fread(mem, fd);
            fsize = n;
            $fclose(fd);
            $display("[info] 载入 %0d 字节", fsize);
        end

        #100 rst_n = 1'b1;
        repeat (20) @(posedge clk);

        // 等图片读完
        wait (rd_done);
        repeat (200) @(posedge clk);

        $display("[info] 图片: 收 %0d 字节，错 %0d；音频: 收 %0d 字，错 %0d",
                 b_got, b_bad, a_got, a_bad);
        if (b_got != 8*512) begin
            $display("[FAIL] 图片只收到 %0d 字节，应 4096（扇区没收满 -> 上板就是黑屏）", b_got);
            errs = errs + 1;
        end else if (b_bad != 0) begin
            $display("[FAIL] 图片字节错 %0d 个", b_bad);
            errs = errs + 1;
        end else
            $display("[ok] 图片 8 个扇区逐字节正确");

        if (a_got < 3*256) begin
            $display("[FAIL] 音频只收到 %0d 字（应 >=768）", a_got);
            errs = errs + 1;
        end else if (a_bad != 0) begin
            $display("[FAIL] 音频字错 %0d 个（仲裁串数据）", a_bad);
            errs = errs + 1;
        end else
            $display("[ok] 音频在图片读期间插队，数据没有串");

        if (errs == 0) $display("[PASS] sd_arb + sd_bmp_reader 联调通过");
        else           $display("[FAIL] 共 %0d 处错误", errs);
        $finish;
    end

    // 音频客户端：等图片读到第 2 个扇区时插进来抢总线
    initial begin : aud_req
        integer k;
        wait (rst_n);
        wait (b_got > 400);
        for (k = 0; k < 4; k = k + 1) begin
            a_sec = a_base + k;
            a_req = 1'b1;
            @(posedge clk);
            wait (a_busy);
            a_req = 1'b0;
            wait (!a_busy);
            repeat (5) @(posedge clk);
        end
    end

    // 超时保护
    initial begin
        #40_000_000;
        $display("[FAIL] 超时（握手卡死）: 图片 %0d 字节, st=%0d", b_got, f_st);
        $finish;
    end

endmodule
