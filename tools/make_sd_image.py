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
WAV_SR     = 48000     # 必须与 HDMI 的 ACR 一致（N=6144/CTS=37500 @37.5MHz）


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


def read_wav(path):
    """读 WAV 并返回 (channels, rate, bits, data_bytes)

    只接受 PCM / 单声道 / 16bit / 48kHz。
    会跳过 LIST 等附加块 —— ffmpeg 默认会插一个 LIST(encoder)，
    那样 data 就不在 44 字节处，而 RTL 是固定跳 44 字节的，
    所以这里统一**重写规范头**（见 write_wav_canonical）。
    """
    with open(path, "rb") as f:
        d = f.read()
    if d[:4] not in (b"RIFF", b"RF64"):
        raise ValueError("不是 RIFF/WAV")
    i, fmt, data = 12, None, None
    while i + 8 <= len(d):
        cid = d[i:i+4]
        sz = struct.unpack("<I", d[i+4:i+8])[0]
        body = d[i+8:i+8+sz]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            data = body
            break
        i += 8 + sz + (sz & 1)
    if fmt is None or data is None:
        raise ValueError("缺 fmt/data 块")
    tag = struct.unpack("<H", fmt[0:2])[0]
    ch = struct.unpack("<H", fmt[2:4])[0]
    rate = struct.unpack("<I", fmt[4:8])[0]
    bits = struct.unpack("<H", fmt[14:16])[0]
    if tag == 0xFFFE and len(fmt) >= 26:      # WAVE_FORMAT_EXTENSIBLE
        tag = struct.unpack("<H", fmt[24:26])[0]
        bits = struct.unpack("<H", fmt[18:20])[0]
    if tag != 1:
        raise ValueError("不是 PCM（format tag=%d）" % tag)
    if ch != 1:
        raise ValueError("%d 声道（需要单声道，ffmpeg: -ac 1）" % ch)
    if bits != 16:
        raise ValueError("%d bit（需要 16bit，ffmpeg: -sample_fmt s16）" % bits)
    if rate != WAV_SR:
        raise ValueError("%d Hz（需要 48000，ffmpeg: -ar 48000）" % rate)
    return ch, rate, bits, data


def wav_canonical(data):
    """把 PCM 数据包成 44 字节规范头（RTL 固定跳 22 个字）"""
    n = len(data)
    hdr = b"RIFF" + struct.pack("<I", 36 + n) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, WAV_SR, WAV_SR * 2, 2, 16)
    hdr += b"data" + struct.pack("<I", n)
    return hdr + data


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

    if args:
        wavs = []
    else:
        wavs = sorted(glob.glob(os.path.join(ROOT, "音乐资源", "*.wav")))

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

    # ---- 音乐区：紧接图片区，每首占固定扇区数 ----
    wav_info = []
    for p in wavs:
        try:
            ch, rate, bits, data = read_wav(p)
        except Exception as e:
            raise SystemExit("%s : %s" % (os.path.basename(p), e))
        blob = wav_canonical(data)
        wav_info.append((p, blob, "%d 采样 (%.1f 秒)" % (len(data) // 2, len(data) / 2.0 / WAV_SR)))

    mus_base   = SEC_BASE + len(files) * stride
    mus_stride = max([sectors(len(b)) for _, b, _ in wav_info]) if wav_info else 0
    mus_bytes  = mus_stride * SEC_SIZE

    total = (mus_base + len(wav_info) * mus_stride) * SEC_SIZE
    if total < SEC_BASE * SEC_SIZE + len(files) * img_max:
        total = SEC_BASE * SEC_SIZE + len(files) * img_max
    buf = bytearray(total)

    for i, (p, sz, msg) in enumerate(info):
        data = open(p, "rb").read()
        base = SEC_BASE * SEC_SIZE + i * img_max
        buf[base:base + len(data)] = data
        print("[%d] %-40s %7d 字节 @扇区 %-6d %s"
              % (i, os.path.basename(p), len(data), SEC_BASE + i * stride, msg))

    # ---- 写音乐区 ----
    for i, (p, blob, msg) in enumerate(wav_info):
        base = (mus_base + i * mus_stride) * SEC_SIZE
        buf[base:base + len(blob)] = blob
        print("[M%d] %-39s %7d 字节 @扇区 %-6d %s"
              % (i + 1, os.path.basename(p), len(blob), mus_base + i * mus_stride, msg))

    with open(out, "wb") as f:
        f.write(buf)

    print("-" * 74)
    print("共 %d 张图、%d 首音乐，镜像 %d 字节 (%.2f MB)"
          % (len(files), len(wav_info), total, total / 1048576.0))
    if wav_info:
        print("       ↑ 音乐区：把 MUS_BASE=%d、MUS_STRIDE=%d、MUS_NUM=%d 抄进 rtl/top_board.v"
              % (mus_base, mus_stride, len(wav_info)))
    print()
    print("下一步：tools\\write_sd.bat 右键以管理员身份运行，把镜像写进 SD 卡。")
    print("注意：写入会覆盖卡的分区表，写完后卡在 Windows 里不可读，属正常。")


if __name__ == "__main__":
    main()
