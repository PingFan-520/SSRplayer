// ============================================================================
//  key_ctrl.v —— 按键同步 / 去抖 / 长按连发
//
//  按键低有效（板上按键按下为 0）
//  press : 按下瞬间单拍
//  rep   : 长按 REPEAT_DELAY 后，每 1/REPEAT_HZ 秒一个单拍
// ============================================================================
`timescale 1ns / 1ps

module key_one #(
    parameter integer CLK_HZ       = 75_000_000,
    parameter integer DEBOUNCE_MS  = 20,
    parameter integer REPEAT_DELAY_MS = 500,
    parameter integer REPEAT_HZ    = 10
)(
    input  wire clk,
    input  wire rst,
    input  wire key,          // 低有效
    output reg  press,
    output reg  rep
);

    localparam integer DEB_CYC = CLK_HZ / 1000 * DEBOUNCE_MS;
    localparam integer RDL_CYC = CLK_HZ / 1000 * REPEAT_DELAY_MS;
    localparam integer RPT_CYC = CLK_HZ / REPEAT_HZ;

    reg [1:0]  sync;
    reg        stable;
    reg [31:0] db_cnt;
    reg [31:0] hold_cnt;
    reg [31:0] rep_cnt;
    reg        rep_armed;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync      <= 2'b11;
            stable    <= 1'b1;
            db_cnt    <= 32'd0;
            hold_cnt  <= 32'd0;
            rep_cnt   <= 32'd0;
            rep_armed <= 1'b0;
            press     <= 1'b0;
            rep       <= 1'b0;
        end else begin
            sync   <= {sync[0], key};
            press  <= 1'b0;
            rep    <= 1'b0;

            // ---- 去抖 ----
            if (sync[1] == stable) begin
                db_cnt <= 32'd0;
            end else if (db_cnt >= DEB_CYC - 1) begin
                db_cnt <= 32'd0;
                stable <= sync[1];
                if (stable && !sync[1])      // 1 -> 0 即按下
                    press <= 1'b1;
            end else begin
                db_cnt <= db_cnt + 32'd1;
            end

            // ---- 长按连发 ----
            if (stable) begin                    // 松开
                hold_cnt  <= 32'd0;
                rep_cnt   <= 32'd0;
                rep_armed <= 1'b0;
            end else if (!rep_armed) begin
                if (hold_cnt >= RDL_CYC - 1) begin
                    rep_armed <= 1'b1;
                    hold_cnt  <= 32'd0;
                    rep       <= 1'b1;        // 到达延时先发一次
                end else begin
                    hold_cnt <= hold_cnt + 32'd1;
                end
            end else begin
                if (rep_cnt >= RPT_CYC - 1) begin
                    rep_cnt <= 32'd0;
                    rep     <= 1'b1;
                end else begin
                    rep_cnt <= rep_cnt + 32'd1;
                end
            end
        end
    end

endmodule


module key_ctrl #(
    parameter integer CLK_HZ = 75_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [3:0] key_in,     // {OK, DOWN, UP, MENU}
    output wire [3:0] press,
    output wire [3:0] rep
);

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_key
            key_one #(.CLK_HZ(CLK_HZ)) u_key (
                .clk   (clk),
                .rst   (rst),
                .key   (key_in[i]),
                .press (press[i]),
                .rep   (rep[i])
            );
        end
    endgenerate

endmodule
