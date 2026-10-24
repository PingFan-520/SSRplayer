#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_sd_image.py —— 生成 SD 卡裸扇区镜像（不实现 FAT32）

布局（必须与 top_board.v 的 SEC_BASE / SEC_STRIDE 一致）：
    扇区 2048（= 1MB 偏移）起放第 0 张图
    第 i 张图 = 扇区 2048 + i * 1801
    每张图占 1801 个扇区 = 922112 字节（640x480 24bit BMP 需要 921654 字节）

为什么用裸扇区：
    参考工程也是这个策略（sd_read_photo 从扇区 1801 起连续读）。
    要做 FAT32 得实现目录遍历和簇链，工作量和风险都大得多，
    比赛演示用裸扇区足够。

⚠ 写入后这块卡的 FAT 表会被覆盖，Windows 不再识别，请用一张闲置卡。

用法：
    python tools/make_sd_image.py                       # 用 图片资源/*.bmp
    python tools/make_sd_image.py -o out.img a.bmp b.bmp

写入 SD 卡（任选其一）：
    Win32DiskImager / Rufus / balenaEtcher  选 sd_image.img 写入
"""

import os
import sys
import struct
import glob

ROOT      = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC_BASE   = 2048
SEC_STRIDE = 1801
SEC_SIZE   = 512
IMG_MAX    = SEC_STRIDE * SEC_SIZE      # 922112
BMP_NEED   = 640 * 480 * 3 + 54         # 921654


def probe_bmp(path):
    """返回 (ok, 说明)"""
    with open(path, "rb") as f:
        h = f.read(54)
    if len(h) < 54:
        return False, "文件太短"
    if h[:2] != b"BM":
        return False, "不是 BMP（缺 BM 头）"
    size = struct.unpack("<I", h[2:6])[0]
    off  = struct.unpack("<I", h[10:14])[0]
    w, hh = struct.unpack("<ii", h[18:26])
    bpp  = struct.unpack("<H", h[28:30])[0]
    comp = struct.unpack("<I", h[30:34])[0]
    if w != 640 or abs(hh) != 480:
        return False, "尺寸 %dx%d，要求 640x480" % (w, abs(hh))
    if bpp != 24:
        return False, "%d bit，要求 24 bit" % bpp
    if comp != 0:
        return False, "压缩方式 %d，只支持未压缩" % comp
    real = os.path.getsize(path)
    if real > IMG_MAX:
        return False, "文件 %d 字节 > 每张配额 %d" % (real, IMG_MAX)
    return True, "ok  size=%d off=%d" % (size, off)


def main():
    args = sys.argv[1:]
    out = os.path.join(ROOT, "sd_image.img")
    if args and args[0] == "-o":
        out = args[1]
        args = args[2:]

    if args:
        files = args
    else:
        files = sorted(glob.glob(os.path.join(ROOT, "图片资源", "*.bmp")))

    if not files:
        raise SystemExit("没找到 BMP")

    if len(files) > 255:
        raise SystemExit("图片张数 %d 超过 8 位索引上限" % len(files))

    print("输出: %s" % out)
    print("布局: 扇区 %d 起，每张 %d 扇区（%d 字节）" % (SEC_BASE, SEC_STRIDE, IMG_MAX))
    print("-" * 72)

    total = SEC_BASE * SEC_SIZE + len(files) * IMG_MAX
    buf = bytearray(total)

    for i, p in enumerate(files):
        ok, msg = probe_bmp(p)
        name = os.path.basename(p)
        if not ok:
            raise SystemExit("[%d] %s : %s" % (i, name, msg))
        data = open(p, "rb").read()
        base = SEC_BASE * SEC_SIZE + i * IMG_MAX
        buf[base:base + len(data)] = data
        print("[%d] %-46s %7d 字节  @扇区 %d  (%s)"
              % (i, name, len(data), SEC_BASE + i * SEC_STRIDE, msg))

    with open(out, "wb") as f:
        f.write(buf)

    print("-" * 72)
    print("共 %d 张，镜像 %d 字节 (%.2f MB)" % (len(files), total, total / 1048576.0))
    print()
    print("下一步：用 Win32DiskImager / Rufus 把 %s 写入闲置 SD 卡。" % os.path.basename(out))
    print("注意：写入会覆盖卡的分区表，写完后卡在 Windows 里不可读，属正常。")


if __name__ == "__main__":
    main()
