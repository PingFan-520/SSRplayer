# -*- coding: utf-8 -*-
"""
gen_font.py —— 生成 16x16 点阵字模 ROM（Verilog）

用法: python tools/gen_font.py
输出: rtl/ui/font_rom.v

字模编码（与 osd_menu.v 中的常量必须一致）:
    0..25  A-Z
    26..35 0-9
    36     %
    37     空格
    38     /
    39     :
    40     >
    41     -
    42..   中文（见 CN_ORDER）
每字 16 行 x 16 bit，行内 bit15 为最左像素。
"""
import os
from PIL import Image, ImageDraw, ImageFont

CN_ORDER = "调试菜单切屏效果亮度对比缩放模式字幕音量"

ASCII = [chr(c) for c in range(ord('A'), ord('Z') + 1)] + \
        [chr(c) for c in range(ord('0'), ord('9') + 1)] + \
        ['%', ' ', '/', ':', '>', '-']

GLYPHS = ASCII + list(CN_ORDER)
assert len(GLYPHS) <= 64, len(GLYPHS)

FONT_CN = r"C:\Windows\Fonts\simsun.ttc"
FONT_EN = r"C:\Windows\Fonts\consola.ttf"

W = H = 16


def render(ch):
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    is_cn = ord(ch) > 127
    if is_cn:
        font = ImageFont.truetype(FONT_CN, 15, index=0)
    else:
        font = ImageFont.truetype(FONT_EN, 14)

    bbox = d.textbbox((0, 0), ch, font=font)
    gw = bbox[2] - bbox[0]
    gh = bbox[3] - bbox[1]
    x = (W - gw) // 2 - bbox[0]
    y = (H - gh) // 2 - bbox[1]
    d.text((x, y), ch, fill=255, font=font)

    rows = []
    for yy in range(H):
        bits = 0
        for xx in range(W):
            bits = (bits << 1) | (1 if img.getpixel((xx, yy)) >= 110 else 0)
        rows.append(bits)
    return rows


def show(ch, rows):
    print("--- %s ---" % ch)
    for r in rows:
        print("".join('#' if (r >> (15 - i)) & 1 else '.' for i in range(16)))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "rtl", "ui", "font_rom.v")
    os.makedirs(os.path.dirname(out), exist_ok=True)

    data = []
    for ch in GLYPHS:
        data.append(render(ch))

    # 目视抽查
    for ch in ['A', '0', '%', '调', '菜', '量']:
        show(ch, data[GLYPHS.index(ch)])

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("// ============================================================================\n")
        f.write("//  font_rom.v —— 16x16 点阵字模（自动生成，勿手改）\n")
        f.write("//  生成脚本: tools/gen_font.py\n")
        f.write("//  字形数: %d，总容量 %d x 16bit\n" % (len(GLYPHS), 1024))
        f.write("// ============================================================================\n")
        f.write("`timescale 1ns / 1ps\n\n")
        f.write("module font_rom (\n")
        f.write("    input  wire        clk,\n")
        f.write("    input  wire [9:0]  addr,      // glyph*16 + row\n")
        f.write("    output reg  [15:0] dout\n")
        f.write(");\n\n")
        f.write("    reg [15:0] mem [0:1023];\n\n")
        f.write("    initial begin\n")
        for i in range(1024):
            if i < len(data) * 16:
                g, r = divmod(i, 16)
                v = data[g][r]
            else:
                v = 0
            f.write("        mem[%4d] = 16'h%04X;\n" % (i, v))
        f.write("    end\n\n")
        f.write("    always @(posedge clk) begin\n")
        f.write("        dout <= mem[addr];\n")
        f.write("    end\n\n")
        f.write("endmodule\n")

    print("\n生成: %s  字形数=%d" % (out, len(GLYPHS)))


if __name__ == "__main__":
    main()
