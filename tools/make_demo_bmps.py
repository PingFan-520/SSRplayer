#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_demo_bmps.py —— 生成 1280x720 演示图，用来验证"自适应缩放"

生成两张（已存在则跳过）：
    图片资源/test_1280x720.bmp   测试卡：边框 + 彩条 + 网格 + 四角标记
    图片资源/photo_1280x720.bmp  由现有 640x480 照片放大而来（真实感）

为什么要这两张：
    640x480 的图走 k=0 直通，看不出缩放。1280x720 走 k=1 -> 640x360，
    能直接对比"整幅缩小显示"和"原来只显示左上 1/4"的区别。
    测试卡四周有白边、四角有彩色方块，一旦被裁切或错位一眼就能看出来。

用法：python tools/make_demo_bmps.py
"""

import os
import glob
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "图片资源")

W, H = 1280, 720


def make_chart(path):
    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)

    # 彩条（上方 1/2）：白 黄 青 绿 品红 红 蓝 黑
    bars = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
            (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
    bw = W // 8
    for i, c in enumerate(bars):
        d.rectangle([i * bw, 0, (i + 1) * bw - 1, H // 2 - 1], fill=c)

    # 灰阶（中间 1/6）：16 级
    gh = H // 6
    for i in range(16):
        v = int(round(i * 255 / 15))
        x0 = i * W // 16
        x1 = (i + 1) * W // 16 - 1
        d.rectangle([x0, H // 2, x1, H // 2 + gh - 1], fill=(v, v, v))

    # 网格（下方 1/3）
    gy0 = H // 2 + gh
    for x in range(0, W, 40):
        d.line([x, gy0, x, H - 1], fill=(60, 60, 60))
    for y in range(gy0, H, 40):
        d.line([0, y, W - 1, y], fill=(60, 60, 60))

    # 中心的横竖中线 + 圆（缩放有偏移会立刻看出来）
    d.line([W // 2, 0, W // 2, H - 1], fill=(255, 255, 255))
    d.line([0, H // 2, W - 1, H // 2], fill=(255, 255, 255))
    for r in (120, 200, 260):
        d.ellipse([W // 2 - r, H // 2 - r, W // 2 + r, H // 2 + r],
                  outline=(255, 128, 0), width=3)

    # 四角标记（被裁切时方块会缺角）
    sq = 60
    marks = [((0, 0), (0, 0, 255)),
             ((W - sq, 0), (0, 255, 0)),
             ((0, H - sq), (255, 255, 0)),
             ((W - sq, H - sq), (255, 0, 0))]
    for (x, y), c in marks:
        d.rectangle([x, y, x + sq - 1, y + sq - 1], fill=c)

    # 外边框 6px 白
    d.rectangle([0, 0, W - 1, H - 1], outline=(255, 255, 255), width=6)

    img.save(path, "BMP")
    print("  -> %s  %dx%d  %d 字节" % (os.path.basename(path), W, H,
                                       os.path.getsize(path)))


def make_photo(path):
    src = None
    for pat in ("fengjing*.bmp", "苹果*.bmp", "A_*.bmp"):
        g = sorted(glob.glob(os.path.join(OUT, pat)))
        if g:
            src = g[0]
            break
    if src is None:
        print("  -- 没有找到可放大的 640x480 照片，跳过")
        return
    im = Image.open(src).convert("RGB")
    im = im.resize((W, H), Image.LANCZOS)
    im.save(path, "BMP")
    print("  -> %s  %dx%d  %d 字节（源 %s）"
          % (os.path.basename(path), W, H, os.path.getsize(path),
             os.path.basename(src)))


def main():
    if not os.path.isdir(OUT):
        raise SystemExit("没有 图片资源/ 目录")

    print("生成 1280x720 演示图：")
    p1 = os.path.join(OUT, "test_1280x720.bmp")
    if os.path.exists(p1):
        print("  -- test_1280x720.bmp 已存在，跳过")
    else:
        make_chart(p1)

    p2 = os.path.join(OUT, "photo_1280x720.bmp")
    if os.path.exists(p2):
        print("  -- photo_1280x720.bmp 已存在，跳过")
    else:
        make_photo(p2)

    print()
    print("下一步：python tools/make_sd_image.py")


if __name__ == "__main__":
    main()
