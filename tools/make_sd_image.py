#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_sd_image.py —— 生成 SD 卡裸扇区镜像（不实现 FAT32）

布局（必须与 top_board.v 的 SEC_BASE / SEC_STRIDE 一致）：
    扇区 SEC_BASE（默认 2048 = 1MB 偏移）起放第 0 张图
    第 i 张图 = 扇区 SEC_BASE + i * SEC_STRIDE
    SEC_STRIDE 由本脚本按"最大那张图"自动算出来并打印，抄进 top_board.v 即可

为什么允许不同尺寸：
    解码器会解析 BMP 头里的 bfSize，收到最后一个字节就让读取器提前收工，
    所以每张图只读自己的实际长度 —— 640x480 的图读 1801 扇区，
    1280x720 的图读 5401 扇区，不会因为配额大而变慢。

为什么用裸扇区：
    参考工程也是这个策略。做 FAT32 得实现目录遍历和簇链，工作量与风险都大得多。

⚠ 写入后这块卡的 FAT 表会被覆盖，Windows 不再识别，请用一张闲置卡。

用法：
    python tools/make_sd_image.py                       # 用 图片资源/*.bmp
    python tools/make_sd_image.py -o out.img a.bmp b.bmp

写入 SD 卡：tools\\write_sd.bat（右键以管理员身份运行）
"""

import os
import sys
import struct
import glob

ROOT       = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SEC_BASE   = 2048
SEC_SIZE   = 512
BMP_MAX_W  = 4096      # bmp_decode 的 o_sx 是 12 位
BMP_MAX_H  = 4096


def probe_bmp(path):
    """返回 (ok, 说明)"""
    with open(path, "rb") as f:
        h = f.read(54)
    if len(h) < 54:
        return False, "文件太短"
    if h[:2] != b"BM":
        return False, "不是 BMP（缺 BM 头）"
    bf  = struct.unpack("<I", h[2:6])[0]
    off = struct.unpack("<I", h[10:14])[0]
    w, hh = struct.unpack("<ii", h[18:26])
    bpp  = struct.unpack("<H", h[28:30])[0]
    comp = struct.unpack("<I", h[30:34])[0]
    if comp != 0:
        return False, "压缩方式 %d，只支持未压缩" % comp
    if bpp != 24:
        return False, "%d bit，只支持 24 bit" % bpp
    if not (1 <= w <= BMP_MAX_W and 1 <= abs(hh) <= BMP_MAX_H):
        return False, "尺寸 %dx%d 超出 1..%d" % (w, abs(hh), BMP_MAX_W)
    real = os.path.getsize(path)
    if real > bf:                       # 有些工具写的 bfSize 偏小
        bf = real
    return True, "%dx%d size=%d off=%d" % (w, abs(hh), bf, off)


def sectors(n):
    """字节数 -> 扇区数，向上取整并对齐到 8（读取器按 512B 扇区走，对齐好看）"""
    s = (n + SEC_SIZE - 1) // SEC_SIZE
    return (s + 7) // 8 * 8


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

    # 先探一遍，算出最大文件 -> 统一配额
    info = []
    for i, p in enumerate(files):
        ok, msg = probe_bmp(p)
        if not ok:
            raise SystemExit("[%d] %s : %s" % (i, os.path.basename(p), msg))
        info.append((p, os.path.getsize(p), msg))

    stride = max(sectors(sz) for _, sz, _ in info)
    img_max = stride * SEC_SIZE

    print("输出: %s" % out)
    print("布局: 扇区 %d 起，每张 %d 扇区（%d 字节）" % (SEC_BASE, stride, img_max))
    print("      ↑ 把 SEC_STRIDE=%d、IMG_NUM=%d 抄进 rtl/top_board.v"
          % (stride, len(files)))
    print("-" * 74)

    total = SEC_BASE * SEC_SIZE + len(files) * img_max
    buf = bytearray(total)

    for i, (p, sz, msg) in enumerate(info):
        data = open(p, "rb").read()
        base = SEC_BASE * SEC_SIZE + i * img_max
        buf[base:base + len(data)] = data
        print("[%d] %-40s %7d 字节 @扇区 %-6d %s"
              % (i, os.path.basename(p), len(data), SEC_BASE + i * stride, msg))

    with open(out, "wb") as f:
        f.write(buf)

    print("-" * 74)
    print("共 %d 张，镜像 %d 字节 (%.2f MB)" % (len(files), total, total / 1048576.0))
    print()
    print("下一步：tools\\write_sd.bat 右键以管理员身份运行，把镜像写进 SD 卡。")
    print("注意：写入会覆盖卡的分区表，写完后卡在 Windows 里不可读，属正常。")


if __name__ == "__main__":
    main()
