#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
prepare_media.py —— 把素材整理成 FPGA 能直接吃的格式

  · 图片：任意 png/jpg/bmp  ->  24bit 未压缩 BMP（最长边不超过 4096）
      bmp_decode 只认 24bit 未压缩；bmp_scale 会做 2^k 等比缩小，
      所以 1280x720、1920x1080 都能直接放，不必手工改尺寸。
  · 音乐：任意 aac/mp3/m4a/flac/wav  ->  单声道 16bit 48kHz WAV（44 字节规范头）

为什么要规范化：
  wav_player 每收一个 16bit 字当**一个采样**用（单声道），并且固定跳过前 22 个字。
  非 44 字节头的 WAV（例如 ffmpeg 默认会插一个 LIST 块）必须重写头。

用法:
    python tools/prepare_media.py            # 处理 图片资源/ 与 音乐资源/
    python tools/prepare_media.py 图片资源 音乐资源
"""

import os
import sys
import glob
import struct
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SR = 48000
MAX_DIM = 4096


def find_ffmpeg():
    """优先用 imageio-ffmpeg 自带的（不需要用户装 ffmpeg）"""
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        pass
    for p in ("ffmpeg", "ffmpeg.exe"):
        try:
            subprocess.run([p, "-version"], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=True)
            return p
        except Exception:
            continue
    return None


def canon_wav(data):
    n = len(data)
    hdr = b"RIFF" + struct.pack("<I", 36 + n) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, SR, SR * 2, 2, 16)
    hdr += b"data" + struct.pack("<I", n)
    return hdr + data


def prep_images(folder):
    from PIL import Image
    n = 0
    for f in sorted(os.listdir(folder)):
        ext = os.path.splitext(f)[1].lower()
        if ext not in (".png", ".jpg", ".jpeg", ".bmp"):
            continue
        p = os.path.join(folder, f)
        im = Image.open(p)
        if im.mode in ("RGBA", "LA", "P"):
            im = im.convert("RGBA")
            bg = Image.new("RGB", im.size, (255, 255, 255))
            bg.paste(im, mask=im.getchannel("A"))
            im = bg
        else:
            im = im.convert("RGB")
        # 超过 4096 就等比缩（bmp_decode 的坐标是 12 位）
        w, h = im.size
        if max(w, h) > MAX_DIM:
            r = MAX_DIM / float(max(w, h))
            im = im.resize((int(w * r), int(h * r)), Image.LANCZOS)
            w, h = im.size
        if ext == ".bmp":
            # 已经是 BMP：只要尺寸合规就不动（避免反复转换掉画质）
            continue
        stem = os.path.splitext(f)[0]
        # 已经转换过（同名的 stem*_24bit.bmp）就跳过，避免同一张图进两遍
        if glob.glob(os.path.join(folder, stem + "*_24bit.bmp")):
            continue
        out = os.path.join(folder, "%s_%dx%d_24bit.bmp" % (stem, w, h))
        im.save(out, "BMP")
        print("  图片 %-40s -> %s" % (f, os.path.basename(out)))
        n += 1
    return n


def prep_audio(folder, ff):
    n = 0
    for f in sorted(os.listdir(folder)):
        ext = os.path.splitext(f)[1].lower()
        if ext not in (".aac", ".mp3", ".m4a", ".flac", ".wav", ".ogg"):
            continue
        p = os.path.join(folder, f)
        out = os.path.join(folder, os.path.splitext(f)[0] + ".wav")
        if ext == ".wav":
            d = open(p, "rb").read(64)
            src = os.path.splitext(f)[0]
            # 已经是规范头就跳过
            if d[36:40] == b"data":
                continue
        if ff is None:
            print("  [跳过] %s：没找到 ffmpeg（pip install imageio-ffmpeg）" % f)
            continue
        # -ac 1 单声道 / -ar 48000 与 HDMI ACR 一致 / s16 定点
        cmd = [ff, "-y", "-i", p, "-ar", str(SR), "-ac", "1",
               "-sample_fmt", "s16", "-c:a", "pcm_s16le", out]
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if r.returncode != 0:
            print("  [失败] %s" % f)
            continue
        # 重写成 44 字节规范头
        import wave
        w = wave.open(out, "rb")
        data = w.readframes(w.getnframes())
        w.close()
        with open(out, "wb") as fo:
            fo.write(canon_wav(data))
        print("  音乐 %-40s -> %s (%.1f 秒)"
              % (f, os.path.basename(out), len(data) / 2.0 / SR))
        n += 1
    return n


if __name__ == "__main__":
    img_dir = os.path.join(ROOT, "图片资源")
    mus_dir = os.path.join(ROOT, "音乐资源")
    if len(sys.argv) >= 2:
        img_dir = sys.argv[1]
    if len(sys.argv) >= 3:
        mus_dir = sys.argv[2]

    ff = find_ffmpeg()
    print("ffmpeg:", ff)
    c1 = prep_images(img_dir) if os.path.isdir(img_dir) else 0
    c2 = prep_audio(mus_dir, ff) if os.path.isdir(mus_dir) else 0
    print("完成：图片 %d 个、音乐 %d 首已规范化" % (c1, c2))
    print("下一步：python tools/make_sd_image.py")
