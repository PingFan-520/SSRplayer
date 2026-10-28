#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_960x540.py —— 把任意图片转成帧缓存尺寸 960x540 的 24bit BMP

为什么是 960x540：
  SDRAM 的 App 地址是 21 位字节地址（2MB），720p 双缓冲放不下，所以帧缓存
  本身就是 960x540，显示时再由读侧做 4:3 上采样铺满 1280x720。
  把图预先做成 960x540 有三个好处：
    1) SD 读图量从 2.76MB 降到 1.56MB，扇区数 5392 -> 3038，加载时间约减半
    2) bmp_scale 走 k=0 直通（img_w==960 && img_h==540 -> 满屏居中偏移 0），
       不再做 2^k 缩小，逻辑最简单、不会因为缩放档位算出黑边
    3) 所有图尺寸一致，切图时的写入矩形完全重合，理论上可以跳过清屏

画法（保持不形变 + 不留黑边）：
  背景 = 原图铺满 960x540（允许拉伸）+ 高斯模糊 + 压暗
  前景 = 原图等比缩放到 960x540 内，居中
  对 16:9 的图，前景正好铺满，背景看不见；对 4:3 / 2:1 的图，两侧或上下
  由模糊背景填满，既不变形也不出现黑边。

用法:
    python tools/make_960x540.py 图片资源 sd960
    python tools/make_960x540.py 图片资源 F:\\          # 直接写 SD 卡
"""

import os
import sys

from PIL import Image, ImageEnhance, ImageFilter

W, H = 960, 540
BG_BLUR = 26          # 背景模糊半径（像素）
BG_DARK = 0.42        # 背景压暗系数


def fit_to_canvas(im):
    """等比缩放到 WxH 内，返回 (缩放后的图, 左上角坐标)"""
    src_w, src_h = im.size
    r = min(W / float(src_w), H / float(src_h))
    nw = max(1, int(round(src_w * r)))
    nh = max(1, int(round(src_h * r)))
    if (nw, nh) != (src_w, src_h):
        im = im.resize((nw, nh), Image.LANCZOS)
    return im, ((W - nw) // 2, (H - nh) // 2)


def convert(src, dst):
    im = Image.open(src)

    # 透明通道：铺黑底（相框背景是暗的，黑底最自然）
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        base = Image.new("RGB", im.size, (0, 0, 0))
        base.paste(im, mask=im.getchannel("A"))
        im = base
    else:
        im = im.convert("RGB")

    # ---- 背景：直接铺满（变形无所谓，模糊后看不出来）----
    bg = im.resize((W, H), Image.LANCZOS)
    bg = bg.filter(ImageFilter.GaussianBlur(BG_BLUR))
    bg = ImageEnhance.Brightness(bg).enhance(BG_DARK)

    # ---- 前景：保持比例 ----
    fg, (ox, oy) = fit_to_canvas(im)
    bg.paste(fg, (ox, oy))

    # 24bit 未压缩 BMP（PIL 的 BMP 是自底向上，bmp_decode 支持）
    bg.save(dst, "BMP")
    return im.size, fg.size, (ox, oy)


def main():
    src_dir = sys.argv[1] if len(sys.argv) >= 2 else "图片资源"
    out_dir = sys.argv[2] if len(sys.argv) >= 3 else "sd960"
    os.makedirs(out_dir, exist_ok=True)

    exts = (".png", ".jpg", ".jpeg", ".bmp")
    files = sorted(f for f in os.listdir(src_dir) if os.path.splitext(f)[1].lower() in exts)
    if not files:
        print("没有找到图片：", src_dir)
        return 1

    for f in files:
        stem = os.path.splitext(f)[0]
        # 8.3 短名：<= 8 字符。字幕显示的就是这个名字。
        if "屏幕截图" in stem:
            # 屏幕截图 2026-10-28 200651 -> S200651（用时间区分，避免重名覆盖）
            tail = "".join(ch for ch in stem[-6:] if ch.isdigit())
            name = ("S" + tail) if len(tail) == 6 else "SHOT"
        else:
            name = (stem.replace("_1280x720_24bit", "")
                        .replace("_640x480_24bit", "")
                        .replace("_24bit", "")
                        .replace("_不翻转", "")
                        .replace("_显示正常", "")
                        .replace("_工程适配版", "")
                        .replace(" ", ""))[:8].upper()
        if not name:
            name = "IMG"
        dst = os.path.join(out_dir, name + ".BMP")
        src_size, fg_size, off = convert(os.path.join(src_dir, f), dst)
        print("%-34s -> %-12s  源 %dx%d 前景 %dx%d @ %s  %d 字节"
              % (f, os.path.basename(dst), src_size[0], src_size[1],
                 fg_size[0], fg_size[1], off, os.path.getsize(dst)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
