// ============================================================================
//  sd_arb.v —— SD 读总线仲裁（音频优先，图片等待）
//
//  背景：sd_ctrl_top 只有一个读口（rd_start_en / rd_sec_addr / rd_busy / rd_val_*），
//        既要读图片（换图时一次 ~1MB），又要读音乐（连续 96KB/s），必须仲裁。
//
//  策略：按**扇区**粒度、音频优先。音频每 5.33ms 要一个扇区，让它插队，
//        图片那次读只会被拉长 ~6%，但音频永远不会断。
//
//  关键约束（踩过的坑）：
//    ① 没拿到总线的那个使用者，必须看到"被门控过"的 busy/val/data，
//       否则它一看到别人把 busy 拉高，就以为自己的命令在跑，会把别人的数据收走。
//    ② owner 在 s_start 那一拍之后才更新，所以地址必须用**组合**选择
//       （start_aud ? a_sec : b_sec），不能用 owner 选，否则第一拍地址是旧的。
//    ③ 一次传输的结束以**真实 busy 落下**为准（seen_busy 之后）。
//       ★ 这一条是上板验证出来的：曾经改成"自己数满 256 个字才释放"，
//         结果图片直接黑屏 —— 客户端的 rd_start_en 是"看到 busy 才撤"，
//         两边的"结束条件"一旦不一致，接收侧就会停在收数中途再也不动。
//         现在恢复成 busy 驱动；数帧由客户端自己做（BMP 读 256 字、WAV 读 256 字）。
//    ④ 看门狗必须有：命令发出去 busy 一直不来（SD 未初始化/上一条没结束）时
//       16 拍后放弃；active 长时间不结束（busy 卡住）时也会强制释放，
//       绝不把总线锁死（老版本 active 停在 15 就是这个教训）。
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
    reg        seen_busy;       // 已经看到本次传输的 busy
    reg        owner;           // 1 = 本次传输属于音频
    reg  [4:0] gap;             // 等 busy 的超时
    reg [18:0] wdog;            // active 的粗看门狗（约 20ms @25MHz）

    wire idle  = ~active & ~s_busy;
    wire gnt_a = idle & sd_init_done &  a_req;
    wire gnt_b = idle & sd_init_done & ~a_req & b_req;
    wire grant = gnt_a | gnt_b;

    // 地址必须组合选择：owner 下一拍才更新，用 owner 选会送错地址
    assign s_start = grant;
    assign s_sec   = gnt_a ? a_sec : b_sec;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 1'b0;
            seen_busy <= 1'b0;
            owner     <= 1'b1;
            gap       <= 5'd0;
            wdog      <= 19'd0;
        end else if (grant) begin
            active    <= 1'b1;
            seen_busy <= 1'b0;
            owner     <= gnt_a;
            gap       <= 5'd0;
            wdog      <= 19'd0;
        end else if (active) begin
            wdog <= wdog + 19'd1;
            if (s_busy) begin
                seen_busy <= 1'b1;
                gap       <= 5'd0;
            end else if (seen_busy) begin
                active    <= 1'b0;              // 正常结束：busy 落下
                seen_busy <= 1'b0;
            end else if (gap == 5'd16) begin
                active    <= 1'b0;              // 命令没被接收：放弃，让客户端重试
            end else begin
                gap <= gap + 5'd1;
            end
            if (wdog == 19'h7FFFF) begin
                active    <= 1'b0;              // busy 卡住的兜底
                seen_busy <= 1'b0;
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
