// ============================================================================
//  afifo.v —— 参数化双时钟异步 FIFO（格雷码指针，寄存器输出）
//
//  读数据是寄存器输出：rd_en 后一拍 rd_data 才更新，
//  这样综合成 BRAM 而不是分布式 RAM。
// ============================================================================
`timescale 1ns / 1ps

module afifo #(
    parameter integer DW = 32,
    parameter integer AW = 10      // 深度 = 2^AW
)(
    input  wire          clk_w,
    input  wire          clk_r,
    input  wire          aclr,

    input  wire          wr_en,
    input  wire [DW-1:0] wr_data,
    output wire          wr_full,

    input  wire          rd_en,
    output wire [DW-1:0] rd_data,
    output wire          rd_empty,
    output wire          rd_valid,     // rd_en 真正被接受（rd_data 本拍有效）
    output wire [AW:0]   wr_used       // 写侧看到的"已用字数"（读指针已同步到写域）
);

    localparam integer PW = AW + 1;

    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg  [PW-1:0] wbin, wgray;
    reg  [PW-1:0] rbin, rgray;
    reg  [DW-1:0] rd_data_r;
    reg           rd_valid_r;

    reg [PW-1:0] rgray_w1, rgray_w2;
    reg [PW-1:0] wgray_r1, wgray_r2;

    wire [PW-1:0] wbin_nxt  = wbin + (wr_en & ~wr_full);
    wire [PW-1:0] wgray_nxt = (wbin_nxt >> 1) ^ wbin_nxt;
    wire [PW-1:0] rbin_nxt  = rbin + (rd_en & ~rd_empty);
    wire [PW-1:0] rgray_nxt = (rbin_nxt >> 1) ^ rbin_nxt;

    assign wr_full  = (wgray == {~rgray_w2[PW-1:PW-2], rgray_w2[PW-3:0]});
    assign rd_empty = (rgray == wgray_r2);
    assign rd_data  = rd_data_r;
    // rd_valid 与 rd_data_r 同拍更新：rd_data 有效的那一拍 rd_valid=1。
    // 关键：必须用 "rd_en & ~rd_empty"，而不是 rd_en —— rd_empty 是跨时钟同步的，
    // FIFO 接近空时它会滞后，若只看 rd_en 会把同一个字重复取两次。
    assign rd_valid = rd_valid_r;

    // 写侧视角的实时占用：写指针 - 同步过来的读指针。
    // 比在外层用"消费脉冲累加"估算可靠得多 —— 后者只要跨域同步边界
    // 多一拍少一拍，误差就会永久累积（实测漂到 2049 > 深度 2048）。
    function [PW-1:0] gray2bin;
        input [PW-1:0] g;
        integer i;
        begin
            gray2bin[PW-1] = g[PW-1];
            for (i = PW-2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [PW-1:0] rbin_w2 = gray2bin(rgray_w2);
    // 同步滞后 2 个读时钟 -> wr_used 略微"偏大"，属于安全方向（宁可早停不溢出）
    assign wr_used = wbin - rbin_w2;

    always @(posedge clk_w or posedge aclr) begin
        if (aclr) begin
            wbin     <= {PW{1'b0}};
            wgray    <= {PW{1'b0}};
            rgray_w1 <= {PW{1'b0}};
            rgray_w2 <= {PW{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            if (wr_en & ~wr_full) begin
                mem[wbin[AW-1:0]] <= wr_data;
                wbin  <= wbin_nxt;
                wgray <= wgray_nxt;
            end
        end
    end

    always @(posedge clk_r or posedge aclr) begin
        if (aclr) begin
            rbin      <= {PW{1'b0}};
            rgray     <= {PW{1'b0}};
            wgray_r1  <= {PW{1'b0}};
            wgray_r2  <= {PW{1'b0}};
            rd_data_r <= {DW{1'b0}};
            rd_valid_r <= 1'b0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            rd_valid_r <= rd_en & ~rd_empty;
            if (rd_en & ~rd_empty) begin
                rd_data_r <= mem[rbin[AW-1:0]];
                rbin      <= rbin_nxt;
                rgray     <= rgray_nxt;
            end
        end
    end

endmodule
