// ============================================================================
//  sd_arb.v —— SD 读总线仲裁（音频优先，图片等待）
//
//  背景：sd_ctrl_top 只有一个读口（rd_start_en / rd_sec_addr / rd_busy / rd_val_*）。
//        既要读图片（换图时一次 0.9MB），又要读音乐（连续 96KB/s），必须仲裁。
//
//  策略：**按扇区粒度**、音频优先。
//    音频每 5.3ms 才要一个扇区，让它在前面插队，图片那次读只会被拉长 ~6%，
//    但音频永远不会断（FIFO 里还有 20ms 余量）。
//
//  关键细节（踩过这个坑的人不少）：
//    没拿到总线的那个使用者，必须看到"被门控过"的 busy/val/data。
//    否则它一看到别人把 busy 拉高，就以为自己的命令在跑，会把别人的数据收走。
//
//  时序：owner 在 s_start 那一拍之后才更新，所以地址用**组合**选择
//        （start_aud ? a_sec : b_sec），不能用 owner 选，否则第一拍地址是旧的。
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
    output wire        a_gnt,      // 本次传输归 A（供调试/观测）

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

    // 一次传输进行中的标记：从发出 s_start 起，到 busy 落下为止
    reg [3:0]  active;
    reg        seen_busy;
    reg        owner;              // 1 = 这次传输属于音频

    wire idle = (active == 4'd0) & ~s_busy;

    wire start_aud = idle & sd_init_done &  a_req;
    wire start_bmp = idle & sd_init_done & ~a_req & b_req;

    assign s_start = start_aud | start_bmp;
    assign s_sec   = start_aud ? a_sec : b_sec;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 4'd0;
            seen_busy <= 1'b0;
            owner     <= 1'b1;
        end else begin
            if (s_start) begin
                active    <= 4'd1;
                seen_busy <= 1'b0;
                owner     <= start_aud;          // 这一拍之后按它来门控
            end else if (s_busy) begin
                seen_busy <= 1'b1;
            end else if (active != 4'd0 && seen_busy) begin
                active    <= 4'd0;               // 一次传输结束
                seen_busy <= 1'b0;
            end else if ((active != 4'd0) && !seen_busy) begin
                // 发出去的命令没有回 busy：等 15 拍后**真正释放**总线。
                // 之前这里写到 15 就停住，active 永远不为 0 -> idle 恒为 0 ->
                // 音频和图片双双饿死（表现为音乐卡顿/爆音）。
                active <= (active == 4'd15) ? 4'd0 : (active + 4'd1);
            end
        end
    end

    // 门控：谁没拿到总线，谁就看不到 busy/val/data
    assign a_busy = s_busy &  owner;
    assign a_val  = s_val  &  owner;
    assign a_data = s_data;
    assign a_gnt  = owner;

    assign b_busy = s_busy & ~owner;
    assign b_val  = s_val  & ~owner;
    assign b_data = s_data;
    assign b_gnt  = ~owner;

endmodule
