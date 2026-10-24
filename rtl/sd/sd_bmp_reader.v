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
//  字节流时序：rd_val_data 是 16bit/拍（每 16 个 SPI 周期一次），
//  这里用"当拍出低字节、下一拍出高字节"的方式拆开，
//  bmp_decode 要求相邻字节至少间隔 1 拍，满足。
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

    // ---- 控制 ----
    input  wire        start,          // 单拍：开始读一张图
    input  wire [7:0]  img_idx,        // 当前是第几张（决定起始扇区）
    output reg         busy,
    output reg         done,           // 单拍：一张读完

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

    // ------------------------------------------------------------------
    // 控制信号来自像素域（37.5MHz），这里是 25MHz，必须同步 / 取边沿
    // ------------------------------------------------------------------
    reg  st_s1, st_s2, st_s3;
    reg  [7:0] ix_s1, ix_s2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st_s1 <= 1'b0; st_s2 <= 1'b0; st_s3 <= 1'b0;
            ix_s1 <= 8'd0; ix_s2 <= 8'd0;
        end else begin
            st_s1 <= start;
            st_s2 <= st_s1;
            st_s3 <= st_s2;
            ix_s1 <= img_idx;      // 上层换图后会先等 16 拍，这里再打两拍
            ix_s2 <= ix_s1;
        end
    end

    wire start_p = st_s2 & ~st_s3;          // 上升沿单拍，避免电平保持导致重复启动

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
        end else begin
            done       <= 1'b0;
            byte_valid <= 1'b0;

            // ---- 16bit -> 2 字节 ----
            // 注意顺序：sd_read 的 rx_data_t 是左移拼接（{rx_data_t[14:0], miso}），
            // 所以先收到的那个字节落在 [15:8]。BMP 解码要严格按文件字节序，
            // 这里必须先输出高字节，否则整张图会变成字节交换后的花屏。
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
                    if (start_p && sd_init_done) begin
                        base_sec <= img_base;
                        sec_cnt  <= 16'd0;
                        word_cnt <= 9'd0;
                        busy     <= 1'b1;
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
                        if (sec_cnt + 16'd1 >= SEC_NUM[15:0]) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            st   <= S_IDLE;
                        end else begin
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
