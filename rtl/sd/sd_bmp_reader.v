// ============================================================================
//  sd_bmp_reader.v —— SD 卡扇区连续读取 + 字节流输出
//
//  用途：把 SD 卡上一段连续扇区（一张 BMP 文件）读出来，拆成字节流喂给
//        bmp_decode。
//
//  分区约定（不用 FAT32，裸扇区，PC 端用 tools/make_sd_image.py 生成镜像）：
//    第 i 张图的起始扇区 = SEC_BASE + i * SEC_STRIDE
//    每张图占 SEC_STRIDE 个扇区（640x480 24bit = 921654 字节 -> 1801 扇区）
//
//  一次读一个扇区（CMD17），因为参考工程的 sd_read 只实现了单块读。
//  1801 个扇区约 385ms @25MHz SPI，切换时短暂黑场可以接受。
//
//  握手（2026-10-24 重写）：
//    enable 电平，1 = 请读 img_idx 指定的那张图；
//    done   电平，读完置 1，enable 撤销后清 0；
//    内部 started 标志防止 enable 还高时重复启动。
//
//    之前用"start 脉冲 + busy 上升沿清请求"的写法在上板死锁：
//    busy 抖一下就把请求撤了，reader 还没真正启动，之后电平启动也失效
//    （start_req 已经是 0），现象就是数码管 25（LOAD 态但 busy=0）。
//    改成 enable/done 后，请求不会因为 busy 的任何抖动而丢失。
//
//  字节流时序：rd_val_data 是 16bit/拍（每 16 个 SPI 周期一次），
//    这里"当拍出高字节、下一拍出低字节"，
//    bmp_decode 要求相邻字节至少间隔 1 拍，满足。
// ============================================================================
`timescale 1ns / 1ps

module sd_bmp_reader #(
    parameter integer SEC_BASE   = 2048,     // 第 0 张图的起始扇区（1MB 偏移）
    parameter integer SEC_STRIDE = 1801,     // 每张图占用的扇区数
    parameter integer SEC_NUM    = 1801      // 每张图实际读取的扇区数
)(
    input  wire        clk,            // SD 时钟域（25MHz）
    input  wire        rst,

    // ---- 与 sd_ctrl_top 的读接口 ----
    output reg         rd_start_en,
    output reg  [31:0] rd_sec_addr,
    input  wire        rd_busy,
    input  wire        rd_val_en,
    input  wire [15:0] rd_val_data,
    input  wire        sd_init_done,

    // ---- 控制（电平）----
    input  wire        enable,         // 1 = 开始读 img_idx 对应的一张图
    input  wire [7:0]  img_idx,
    // 双缓冲下写只在"图片行之外"进行，SD 必须能被反压：
    // 写 FIFO 快满时停在上一个扇区之间等，而不是把像素丢掉
    input  wire [7:0]  fifo_used,
    output reg         busy,           // 正在读
    output reg         done,           // 读完（电平保持到 enable 撤销）

    // ---- 字节流输出（进异步 FIFO 再到 pix 域）----
    output reg  [7:0]  byte_data,
    output reg         byte_valid
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_CMD  = 3'd1,
                     S_WT   = 3'd2,
                     S_RCV  = 3'd3,
                     S_GAP  = 3'd4;

    reg [2:0]  st;
    reg [31:0] base_sec;
    reg [15:0] sec_cnt;
    reg [8:0]  word_cnt;
    reg [7:0]  pend;
    reg        pend_v;
    reg        started;

    // ------------------------------------------------------------------
    // 跨时钟同步
    // ------------------------------------------------------------------
    reg  en_s1, en_s2;
    reg  [7:0] ix_s1, ix_s2;
    reg  sdi_s1, sdi_s2;
    reg  [7:0] fu_s1, fu_s2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            en_s1  <= 1'b0;  en_s2  <= 1'b0;
            ix_s1  <= 8'd0;  ix_s2  <= 8'd0;
            sdi_s1 <= 1'b0;  sdi_s2 <= 1'b0;
            fu_s1  <= 8'd0;  fu_s2  <= 8'd0;
        end else begin
            en_s1  <= enable;
            en_s2  <= en_s1;
            ix_s1  <= img_idx;
            ix_s2  <= ix_s1;
            sdi_s1 <= sd_init_done;
            sdi_s2 <= sdi_s1;
            fu_s1  <= fifo_used;
            fu_s2  <= fu_s1;
        end
    end

    // 每张图的起始扇区 = SEC_BASE + img_idx * SEC_STRIDE
    wire [31:0] img_base = SEC_BASE + ix_s2 * SEC_STRIDE;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= S_IDLE;
            rd_start_en <= 1'b0;
            rd_sec_addr <= 32'd0;
            base_sec    <= 32'd0;
            sec_cnt     <= 16'd0;
            word_cnt    <= 9'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            byte_data   <= 8'd0;
            byte_valid  <= 1'b0;
            pend        <= 8'd0;
            pend_v      <= 1'b0;
            started     <= 1'b0;
        end else begin
            // done 必须是"电平保持"而不是单拍脉冲：
            // 它在 25MHz 域产生，上层在 37.5MHz 域用两级同步器采，
            // 40ns 的窄脉冲有可能被整拍漏掉，导致上层永远等不到"读完"。
            byte_valid <= 1'b0;

            // enable 撤销后清掉内部标志，允许下一次启动
            if (!en_s2) begin
                started <= 1'b0;
                done    <= 1'b0;
            end

            // ---- 16bit -> 2 字节 ----
            // SPI 先收到的字节在 [15:8]（sd_read 的 rx_data_t 是左移拼接）
            if (rd_val_en) begin
                byte_data  <= rd_val_data[15:8];
                byte_valid <= 1'b1;
                pend       <= rd_val_data[7:0];
                pend_v     <= 1'b1;
            end else if (pend_v) begin
                byte_data  <= pend;
                byte_valid <= 1'b1;
                pend_v     <= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    // 电平启动 + started 防重复
                    if (en_s2 && sdi_s2 && !started) begin
                        base_sec <= img_base;
                        sec_cnt  <= 16'd0;
                        word_cnt <= 9'd0;
                        busy     <= 1'b1;
                        started  <= 1'b1;
                        st       <= S_CMD;
                    end
                end

                S_CMD: begin
                    rd_sec_addr <= base_sec + {16'd0, sec_cnt};
                    rd_start_en <= 1'b1;
                    st          <= S_WT;
                end

                S_WT: begin
                    rd_start_en <= 1'b0;
                    if (rd_busy) st <= S_RCV;      // sd_read 已开始发命令
                end

                S_RCV: begin
                    if (rd_val_en) begin
                        word_cnt <= word_cnt + 9'd1;
                        if (word_cnt == 9'd255)     // 256 x 16bit = 512 字节
                            st <= S_GAP;
                    end
                end

                S_GAP: begin
                    // 等 sd_read 收完 CRC、rd_busy 落下
                    if (!rd_busy) begin
                        // 一个扇区会往写 FIFO 灌 128 个字（512B / 4B/字），
                        // 余量不足就先停在这里等显示端消费
                        if (sec_cnt + 16'd1 >= SEC_NUM[15:0]) begin
                            busy    <= 1'b0;
                            done    <= 1'b1;
                            started <= 1'b0;
                            st      <= S_IDLE;
                        end else if (fu_s2 < 8'd120) begin
                            sec_cnt  <= sec_cnt + 16'd1;
                            word_cnt <= 9'd0;
                            st       <= S_CMD;
                        end
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
