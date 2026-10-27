// ============================================================================
//  sd_arb.v —— SD 读总线仲裁（音频 > 图片 > 扫描）
//
//  背景：sd_ctrl_top 只有一个读口，现在有三个使用者：
//    A 音频（每 5.33ms 一个扇区，不能断）
//    B 图片（换图时一次几百 KB）
//    C FAT 扫描（只在开机挂载/目录扫描时用，播放期间完全空闲）
//
//  策略：按**扇区**粒度、A 最优先，B 次之，C 最后。
//        C 只在开机阶段有请求，所以正常播放时和以前完全一样。
//
//  关键约束（踩过的坑，一条都不能改）：
//    ① 没拿到总线的使用者，必须看到"被门控过"的 busy/val/data；
//    ② 地址必须在 grant 那拍**锁存**，不能用 owner 组合选择
//       （sd_read 是 start 之后第 2 拍才锁地址，组合选择会拿到别人的扇区）；
//    ③ 一次传输的结束以**真实 busy 落下**为准；
//    ④ 看门狗必须有，绝不把总线锁死。
// ============================================================================
`timescale 1ns / 1ps

module sd_arb (
    input  wire        clk,        // 25MHz（与 sd_ctrl_top 同域）
    input  wire        rst_n,

    // ---- 使用者 A：音频（最高优先）----
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

    // ---- 使用者 C：FAT 扫描 ----
    input  wire        c_req,
    input  wire [31:0] c_sec,
    output wire        c_busy,
    output wire        c_val,
    output wire [15:0] c_data,
    output wire        c_gnt,

    // ---- 到 sd_ctrl_top ----
    output wire        s_start,
    output wire [31:0] s_sec,
    input  wire        s_busy,
    input  wire        s_val,
    input  wire [15:0] s_data,

    input  wire        sd_init_done   // 初始化完成前不允许发命令
);

    localparam [1:0] O_NONE = 2'd0,
                     O_AUD  = 2'd1,
                     O_IMG  = 2'd2,
                     O_SCAN = 2'd3;

    reg        active;          // 一次传输进行中
    reg        seen_busy;       // 已经看到本次传输的 busy
    reg  [1:0] owner;           // 本次传输属于谁
    reg  [4:0] gap;             // 等 busy 的超时
    reg [18:0] wdog;            // active 的粗看门狗（约 20ms @25MHz）

    reg [31:0] sec_hold;        // 本次传输的扇区地址（在 grant 那拍锁存）

    wire idle  = ~active & ~s_busy;
    wire gnt_a = idle & sd_init_done &  a_req;
    wire gnt_b = idle & sd_init_done & ~a_req & b_req;
    wire gnt_c = idle & sd_init_done & ~a_req & ~b_req & c_req;
    wire grant = gnt_a | gnt_b | gnt_c;

    assign s_start = grant;
    assign s_sec   = sec_hold;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active    <= 1'b0;
            seen_busy <= 1'b0;
            owner     <= O_NONE;
            sec_hold  <= 32'd0;
            gap       <= 5'd0;
            wdog      <= 19'd0;
        end else if (grant) begin
            active    <= 1'b1;
            seen_busy <= 1'b0;
            owner     <= gnt_a ? O_AUD : (gnt_b ? O_IMG : O_SCAN);
            sec_hold  <= gnt_a ? a_sec : (gnt_b ? b_sec : c_sec);  // 锁存
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
    assign a_busy = s_busy & (owner == O_AUD);
    assign a_val  = s_val  & (owner == O_AUD);
    assign a_data = s_data;
    assign a_gnt  = (owner == O_AUD);

    assign b_busy = s_busy & (owner == O_IMG);
    assign b_val  = s_val  & (owner == O_IMG);
    assign b_data = s_data;
    assign b_gnt  = (owner == O_IMG);

    assign c_busy = s_busy & (owner == O_SCAN);
    assign c_val  = s_val  & (owner == O_SCAN);
    assign c_data = s_data;
    assign c_gnt  = (owner == O_SCAN);

endmodule
