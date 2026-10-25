#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
cmp_scale.py —— 校验 tb_bmp_scale_chain 的输出

把 sim/scale_out.raw（640x480 RGB565，小端）与源 BMP 按 bmp_scale 的规则
（2^k 等比缩小 + 居中）逐像素比对，并输出 PNG 便于肉眼检查。

用法：python sim/cmp_scale.py [源bmp]
"""

import os
import sys
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DW, DH = 640, 480


def load_bmp(path):
    with open(path, "rb") as f:
        d = f.read()
    off = struct.unpack("<I", d[10:14])[0]
    w, h = struct.unpack("<ii", d[18:26])
    bpp = struct.unpack("<H", d[28:30])[0]
    assert bpp == 24, "只支持 24bit"
    top_down = h < 0
    h = abs(h)
    stride = (w * 3 + 3) // 4 * 4
    return d, off, w, h, stride, top_down


def src_px(d, off, w, h, stride, top_down, x, y):
    """返回 BMP 上 (x,y) 的 RGB565（y 为显示序，0=顶部）"""
    row = y if top_down else (h - 1 - y)
    p = off + row * stride + x * 3
    b, g, r = d[p], d[p + 1], d[p + 2]
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def calc_k(w, h):
    """FIT：两轴同一个 k，使整幅图塞进框"""
    for k in range(5):
        if (w >> k) <= DW and (h >> k) <= DH:
            return k
    return 4


def calc_kw(w):
    """STRETCH：只看宽度"""
    for k in range(5):
        if (w >> k) <= DW:
            return k
    return 4


def axes(w, h, mode):
    """返回 (kx, ky)，与 bmp_scale.v 的选择逻辑一致"""
    if mode == 0:
        k = calc_k(w, h)
        return k, k
    if mode == 1:
        return 0, 0
    return calc_kw(w), 0


def main():
    mode = 0
    args = [a for a in sys.argv[1:]]
    if args and args[0].startswith("--mode="):
        mode = int(args[0].split("=")[1])
        args = args[1:]
    src = args[0] if args else os.path.join(ROOT, "sim", "scale_in.bmp")
    raw = os.path.join(ROOT, "sim", "scale_out.raw")

    d, off, w, h, stride, top_down = load_bmp(src)
    kx, ky = axes(w, h, mode)
    w2, h2 = w >> kx, h >> ky
    # 有符号居中偏移（源比框大时为负 -> 裁切），与 RTL 的 >>> 1 一致
    xoff, yoff = (DW - w2) // 2, (DH - h2) // 2

    data = open(raw, "rb").read()
    assert len(data) == DW * DH * 2, "raw 大小 %d 不对" % len(data)

    bad = 0
    rowbad = [0] * DH
    for dy in range(DH):
        for dx in range(DW):
            o = (dy * DW + dx) * 2
            got = data[o] | (data[o + 1] << 8)
            sx, sy = dx - xoff, dy - yoff
            if 0 <= sx < w2 and 0 <= sy < h2:
                exp = src_px(d, off, w, h, stride, top_down, sx << kx, sy << ky)
            else:
                exp = 0
            if got != exp:
                bad += 1
                rowbad[dy] += 1

    tot = DW * DH
    mname = {0: "FIT", 1: "FILL", 2: "STRETCH"}.get(mode, "?")
    print("源图 %dx%d  mode=%d(%s)  kx=%d ky=%d  显示 %dx%d  偏移 (%d,%d)"
          % (w, h, mode, mname, kx, ky, w2, h2, xoff, yoff))
    print("像素 %d  错 %d  = %.2f%% ok" % (tot, bad, 100.0 * (tot - bad) / tot))
    for dy in list(range(0, 8)) + list(range(max(0, yoff - 2), yoff + 3)) + [DH - 1]:
        if 0 <= dy < DH:
            print("  row %3d : %d wrong" % (dy, rowbad[dy]))

    # 输出 PNG
    try:
        from PIL import Image
        im = Image.new("RGB", (DW, DH))
        px = im.load()
        for dy in range(DH):
            for dx in range(DW):
                o = (dy * DW + dx) * 2
                v = data[o] | (data[o + 1] << 8)
                px[dx, dy] = (((v >> 11) & 31) << 3, ((v >> 5) & 63) << 2, (v & 31) << 3)
        out = os.path.join(ROOT, "sim",
                           "scale_out.png" if mode == 0 else "scale_mode%d.png" % mode)
        im.save(out)
        print("图像: %s" % out)
    except ImportError:
        pass

    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
