// ============================================================================
//  sdram_app_model.v —— 仅用于仿真的 SDRAM App 行为模型（按 APUG011 规则收紧）
//
//  规则（来自官方文档）：
//    - 读延迟 10 拍（LATENCY 默认 10）
//    - 读写不能同时：同时发起会打印违规并计数
//    - 周期性刷新：ref_vld 拉高期间不允许访问，busy 同时拉高
//
//  真机用 rtl/mem/sdram.v + IS42s32200 引脚模型，本文件不参与综合。
// ============================================================================
`timescale 1ns / 1ps

module sdram_app_model #(
    parameter integer LATENCY    = 10,
    parameter integer REF_PERIOD = 1000,   // 每 1000 拍刷新一次（仿真加速）
    parameter integer REF_LEN    = 20
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [20:0] wr_addr,
    input  wire [31:0] wr_din,
    input  wire        wr_en,
    input  wire [20:0] rd_addr,
    input  wire        rd_en,
    output reg  [31:0] rd_dout,
    output reg         rd_valid,

    output reg         ref_vld,
    output reg         busy,
    output wire        init_done,
    output reg  [15:0] violation
);

    reg [31:0] mem [0:(1<<21)-1];

    reg [20:0] pipe_addr [0:LATENCY-1];
    reg        pipe_en   [0:LATENCY-1];
    integer    i;

    reg [7:0]  init_cnt = 8'd0;
    reg [15:0] ref_cnt  = 16'd0;
    reg [5:0]  ref_wait = 6'd0;

    assign init_done = (init_cnt == 8'd255);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            init_cnt  <= 8'd0;
            ref_cnt   <= 16'd0;
            ref_wait  <= 6'd0;
            ref_vld   <= 1'b0;
            busy      <= 1'b0;
            rd_valid  <= 1'b0;
            violation <= 16'd0;
            for (i = 0; i < LATENCY; i = i + 1) pipe_en[i] <= 1'b0;
        end else begin
            if (init_cnt != 8'd255) init_cnt <= init_cnt + 8'd1;

            // ---------------- 刷新 ----------------
            if (ref_wait != 6'd0) begin
                ref_wait <= ref_wait - 6'd1;
                ref_vld  <= 1'b1;
                busy     <= 1'b1;
            end else if (ref_cnt >= REF_PERIOD[15:0]) begin
                ref_cnt  <= 16'd0;
                ref_wait <= REF_LEN[5:0];
                ref_vld  <= 1'b1;
                busy     <= 1'b1;
            end else begin
                ref_cnt <= ref_cnt + 16'd1;
                ref_vld <= 1'b0;
                busy    <= 1'b0;
            end

            // ---------------- 违规检测 ----------------
            if (wr_en && rd_en)
                violation <= violation + 16'd1;
            if ((wr_en || rd_en) && ref_vld)
                violation <= violation + 16'd1;

            // ---------------- 写 ----------------
            if (wr_en && !ref_vld)
                mem[wr_addr] <= wr_din;

            // ---------------- 读流水线 ----------------
            pipe_en[0]   <= rd_en && !ref_vld;
            pipe_addr[0] <= rd_addr;
            for (i = 1; i < LATENCY; i = i + 1) begin
                pipe_en[i]   <= pipe_en[i-1];
                pipe_addr[i] <= pipe_addr[i-1];
            end

            rd_valid <= pipe_en[LATENCY-1];
            if (pipe_en[LATENCY-1])
                rd_dout <= mem[pipe_addr[LATENCY-1]];
        end
    end

    // 仿真开始清前 1M 字（两块 buffer）
    initial begin
        for (i = 0; i < (1<<20); i = i + 1) mem[i] = 32'd0;
    end

endmodule
