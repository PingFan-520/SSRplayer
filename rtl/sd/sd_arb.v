// ============================================================================
//  sd_arb.v —— SD 读总线仲裁（音频优先，图片等待）
//
//  背景：sd_ctrl_top 只有一个读口（rd_start_en / rd_sec_addr / rd_busy / rd_val_*），
//        既要读图片（换图时一次 ~1MB），又要读音乐（连续 96KB/s），必须仲裁。
//
//  策略：按**扇区**粒度、音频优先。音频每 5.33ms 要一个扇区，让它插队，
//        图片那次读只会被拉长 ~6%，但音频永远不会断。
//
//  ★ 核心：**由仲裁器自己数满 256 个字**（一个扇区 = 512B = 256 x 16bit）。
//    拿到总线的使用者一次只会收到 256 个字，不多不少。
//
//    为什么必须这样：上一版靠"盯 busy 的上升/下降沿"判断一次传输的开始和结束，
//    再把 s_val 直接门控给 owner。实板上 rd_val_en 的拍数/相位和仿真模型并不
//    完全一样（CRC 尾字、切主瞬间的残留拍），一旦多给或少给一个字，
//    接收侧的字节流就整体错位半个采样：
//      · 图片侧 -> BMP 解码错位 -> 花屏
//      · 音频侧 -> 采样错位     -> 尖锐的沙沙/爆音
//    现在帧长度由仲裁器保证，接收侧不会再收到"半截扇区"。
//
//    实现上**不依赖 busy 的边沿**：授权后进入 active，此后 s_val 来一个放行一个，
//    数到 256 就等 busy 落下再释放（busy 早落下也不影响）。
//    另有两个看门狗，任何异常都不会把总线锁死（上一版 active 卡在 15 的教训）。
// ============================================================================
`timescale 1ns / 1ps

module sd_arb (
    input  wire        clk,        // 25MHz（与 sd_ctrl_top 同域）
    input  wire        rst_n,

    // ---- 使用者 A：音频（优先）----
    input  wire        a_req,
    input  wire [31:0] a_sec,
    output wire        a_busy,
    output wire        a_val,
    output wire [15:0] a_data,
    output wire        a_gnt,

    // ---- 使用者 B：图片 ----
    input  wire        b_req,
    input  wire [31:0] b_sec,
    output wire        b_busy,
    output wire        b_val,
    output wire [15:0] b_data,
    output wire        b_gnt,

    // ---- 到 sd_ctrl_top ----
    output wire        s_start,
    output wire [31:0] s_sec,
    input  wire        s_busy,
    input  wire        s_val,
    input  wire [15:0] s_data,

    input  wire        sd_init_done   // 初始化完成前不允许发命令
);

    reg        active;          // 一次传输进行中
    reg        owner;           // 1 = 本次传输属于音频
    reg  [8:0] wc;              // 已放行的字数
    reg        wend;            // 256 字已收满，只等 busy 落下
    reg [13:0] stall;           // 等不到数据的看门狗

    wire idle  = ~active & ~s_busy;
    wire gnt_a = idle & sd_init_done &  a_req;
    wire gnt_b = idle & sd_init_done & ~a_req & b_req;
    wire grant = gnt_a | gnt_b;

    // 地址必须组合选择：owner 下一拍才更新，用 owner 选会送错地址
    assign s_start = grant;
    assign s_sec   = gnt_a ? a_sec : b_sec;

    // 只放行 active 期间的 s_val，并且只在放行的那一拍算有效
    wire fwd = active & s_val;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            owner  <= 1'b1;
            wc     <= 9'd0;
            wend   <= 1'b0;
            stall  <= 14'd0;
        end else if (!active) begin
            wc    <= 9'd0;
            wend  <= 1'b0;
            stall <= 14'd0;
            if (grant) begin
                active <= 1'b1;
                owner  <= gnt_a;
            end
        end else begin
            if (fwd) begin
                stall <= 14'd0;
                if (wc == 9'd255) wend <= 1'b1;   // 第 256 个字已放行
                else              wc   <= wc + 9'd1;
            end else if (!wend) begin
                // 等数据：超过 16K 拍还没有 -> 放弃（坏卡/未初始化）
                if (stall == 14'h3FFF) begin
                    active <= 1'b0;
                    stall  <= 14'd0;
                end else begin
                    stall <= stall + 14'd1;
                end
            end else if (!s_busy) begin
                active <= 1'b0;                   // 收满且 busy 落下 -> 释放
            end
        end
    end

    // 门控：谁没拿到总线，谁就看不到 busy/val/data
    assign a_busy = active &  owner;
    assign a_val  = fwd    &  owner;
    assign a_data = s_data;
    assign a_gnt  = owner;

    assign b_busy = active & ~owner;
    assign b_val  = fwd    & ~owner;
    assign b_data = s_data;
    assign b_gnt  = ~owner;

endmodule
