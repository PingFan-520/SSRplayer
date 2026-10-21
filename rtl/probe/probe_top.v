// ============================================================================
//  probe_top.v —— P1 频率探针（TMDS PHY 能力实测）
//
//  目的：在写任何视频逻辑之前，回答一个问题——
//        EG4S20 的 LVDS 在 750Mbps（720p60 档）到底能不能稳定工作？
//
//  做法：
//    1. PLL 产生 pixel_clk 与 5x serial_clk（720p 档 75/375MHz，768p 档 65/325MHz）
//    2. CLK 通道：ODDR 恒定输出 d1=1/d0=0 -> 375MHz 方波 = 750Mbps（TMDS 时钟通道波形）
//    3. D0 通道：10:1 串行器输出测试码型
//         key1 松开 -> 0x155 全跳变（测频率/幅度）
//         key1 按下 -> PRBS10 伪随机（测眼图/抖动）
//    4. 数码管：[5]=模式 [4]=倍频比 [3]=锁定 [2:0]=像素域计数
//
//  注意：本工程只做物理层验证，不要接显示器（时序不完整，显示器会报无信号）。
// ============================================================================
`timescale 1ns / 1ps

module probe_top #(
    parameter       MODE_720P   = 1,   // 1: 75/375MHz   0: 65/325MHz
    parameter       IGNORE_LOCK = 0    // 仿真时置 1（厂商模型 extlock 可能不拉高）
)(
    input  wire        clk,            // 50MHz 板载晶振
    input  wire        rst_n,
    input  wire        key1,           // 码型选择：0=方波  1=PRBS

    output wire [5:0]  seg_sel,
    output wire [7:0]  seg_data,

    output wire        HDMI_CLK_P,     // 750Mbps 时钟通道
    output wire        HDMI_D0_P       // 750Mbps 数据通道
);

    // ------------------------------------------------------------------
    // PLL：VCO 反馈模式，VCO = 50MHz x FBCLK_DIV
    //   720p : M=15 -> VCO 750MHz, C0/10=75.000MHz, C1/2=375MHz
    //   768p : M=13 -> VCO 650MHz, C0/10=65.000MHz, C1/2=325MHz
    // ------------------------------------------------------------------
    wire clk_pix;
    wire clk_ser;
    wire locked;

    EG_PHY_PLL #(
        .DPHASE_SOURCE  ("DISABLE"),
        .DYNCFG         ("DISABLE"),
        .FIN            ("50.000000"),
        .FEEDBK_MODE    ("NORMAL"),
        .FEEDBK_PATH    ("VCO_PHASE_0"),
        .STDBY_ENABLE   ("DISABLE"),
        .PLLRST_ENA     ("ENABLE"),
        .SYNC_ENABLE    ("DISABLE"),
        .GMC_GAIN       (2),
        .ICP_CURRENT    (9),
        .KVCO           (2),
        .LPF_CAPACITOR  (1),
        .LPF_RESISTOR   (8),
        .REFCLK_DIV     (1),
        .FBCLK_DIV      (MODE_720P ? 15 : 13),
        .CLKC0_ENABLE   ("ENABLE"),
        .CLKC0_DIV      (10),
        .CLKC0_CPHASE   (9),
        .CLKC0_FPHASE   (0),
        .CLKC1_ENABLE   ("ENABLE"),
        .CLKC1_DIV      (2),
        .CLKC1_CPHASE   (1),
        .CLKC1_FPHASE   (0)
    ) u_pll (
        .refclk     (clk),
        .reset      (~rst_n),
        .stdby      (1'b0),
        .extlock    (locked),
        .load_reg   (5'b00000),
        .psclk      (1'b0),
        .psdown     (1'b0),
        .psstep     (1'b0),
        .psclksel   (3'b000),
        .psdone     (),
        .dclk       (1'b0),
        .dcs        (1'b0),
        .dwe        (1'b0),
        .di         (8'h00),
        .daddr      (6'h00),
        .do         (),
        .fbclk      (1'b0),
        .clkc       ({open, open, open, clk_ser, clk_pix})
    );

    wire lock_ok = locked | IGNORE_LOCK;

    // ------------------------------------------------------------------
    // 复位同步（各时钟域独立释放）
    // ------------------------------------------------------------------
    reg [2:0] rstp_sync;
    always @(posedge clk_pix or negedge rst_n) begin
        if (!rst_n) rstp_sync <= 3'b111;
        else        rstp_sync <= {rstp_sync[1:0], ~lock_ok};
    end
    wire rst_pix = rstp_sync[2];

    reg [2:0] rsts_sync;
    always @(posedge clk_ser or negedge rst_n) begin
        if (!rst_n) rsts_sync <= 3'b111;
        else        rsts_sync <= {rsts_sync[1:0], ~lock_ok};
    end
    wire rst_ser = rsts_sync[2];

    // ------------------------------------------------------------------
    // key1 同步 + 去抖（约 28ms @ 75MHz）
    // ------------------------------------------------------------------
    reg [1:0]  key_sync;
    reg [20:0] db_cnt;
    reg        key_stable;

    always @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) begin
            key_sync   <= 2'b11;
            db_cnt     <= 21'd0;
            key_stable <= 1'b1;
        end else begin
            key_sync <= {key_sync[0], key1};
            if (key_sync[1] == key_stable)
                db_cnt <= 21'd0;
            else if (db_cnt == 21'h1F_FFFF)
                key_stable <= key_sync[1];
            else
                db_cnt <= db_cnt + 21'd1;
        end
    end

    wire pat_prbs = ~key_stable;   // 按下 = PRBS

    // ------------------------------------------------------------------
    // 串行域：10:1 串行器（与 HDMI PHY 同结构：左移 2 位 + ODDR）
    // 0x155 = 0101_0101_01，每拍都在跳变 -> 375MHz 方波（750Mbps）
    // ------------------------------------------------------------------
    reg  [9:0] sr;
    reg  [2:0] bcnt;
    reg  [1:0] oddr_d;
    reg  [9:0] lfsr;
    reg  [9:0] word;

    always @(*) begin
        word = pat_prbs ? lfsr : 10'h155;
    end

    always @(posedge clk_ser or posedge rst_ser) begin
        if (rst_ser) begin
            sr     <= 10'h155;
            bcnt   <= 3'd0;
            oddr_d <= 2'b00;
            lfsr   <= 10'h3FF;
        end else begin
            oddr_d <= sr[9:8];

            if (bcnt == 3'd4) begin
                bcnt <= 3'd0;
                sr   <= word;
                lfsr <= {lfsr[8:0], lfsr[9] ^ lfsr[6]};
            end else begin
                bcnt <= bcnt + 3'd1;
                sr   <= {sr[7:0], 2'b00};
            end
        end
    end

    EG_LOGIC_ODDR u_oddr_d0 (
        .clk (clk_ser),
        .rst (rst_ser),
        .d1  (oddr_d[0]),
        .d0  (oddr_d[1]),
        .q   (HDMI_D0_P)
    );

    EG_LOGIC_ODDR u_oddr_clk (
        .clk (clk_ser),
        .rst (rst_ser),
        .d1  (1'b1),
        .d0  (1'b0),
        .q   (HDMI_CLK_P)
    );

    // ------------------------------------------------------------------
    // 5x 倍频比：pix_tog 每个像素时钟翻转一次，
    // 边沿间隔恰为 1 个像素周期，故间隙的 serial_clk 数即为倍频比（期望 5）
    // ------------------------------------------------------------------
    reg        pix_tog;
    reg [2:0]  tog_sync;
    reg [7:0]  ser_gap;
    reg [3:0]  ratio;

    always @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) pix_tog <= 1'b0;
        else         pix_tog <= ~pix_tog;
    end

    always @(posedge clk_ser or posedge rst_ser) begin
        if (rst_ser) begin
            tog_sync <= 3'b000;
            ser_gap  <= 8'd0;
            ratio    <= 4'd0;
        end else begin
            tog_sync <= {tog_sync[1:0], pix_tog};
            if (tog_sync[2] ^ tog_sync[1]) begin
                ratio   <= ser_gap[3:0] + 4'd1;   // 边沿当拍不计数，补 1
                ser_gap <= 8'd0;
            end else begin
                ser_gap <= ser_gap + 8'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // 像素域自由计数
    // ------------------------------------------------------------------
    reg [23:0] pix_cnt;
    always @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix) pix_cnt <= 24'd0;
        else         pix_cnt <= pix_cnt + 24'd1;
    end

    // ------------------------------------------------------------------
    // 显示
    // ------------------------------------------------------------------
    wire [23:0] disp_val = {
        (MODE_720P ? 4'h1 : 4'h2),
        ratio,
        {3'b000, locked},
        pix_cnt[23:12]
    };

    seg7 #(.CLK_HZ(50_000_000)) u_seg7 (
        .clk     (clk),
        .rst_n   (rst_n),
        .value   (disp_val),
        .dp_mask ({pix_cnt[23], 5'b00000}),
        .seg_sel (seg_sel),
        .seg_data(seg_data)
    );

endmodule
