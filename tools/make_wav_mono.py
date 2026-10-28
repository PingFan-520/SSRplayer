#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_wav_mono.py —— 把任意 WAV 转成播放器要求的 **PCM 16bit / 单声道 / 48kHz**

为什么必须转：
  `wav_player` 每 1/48000 秒从 FIFO 取**一个 16bit 字**当采样输出，也就是它认定
  文件就是"单声道 48kHz 16bit"。拿立体声文件喂进去，一帧（L,R 两个字）要占两拍，
  于是时长翻倍、音调低八度 —— 上板听感就是"被放慢播放"。

做法：
  - L/R 取平均降成单声道（(L+R)/2，不会削顶，也不像只取 L 那样丢内容）
  - 位深统一 16bit、采样率统一 48kHz（不做重采样：本项目素材本来就是 48k）
  - 重写成规范 44 字节头的 WAV（去掉 LIST/INFO 等附加块，解析最简单）
  - 输出 8.3 大写名（SD 卡 FAT32 短名，菜单里显示的就是它）

用法:
    python tools/make_wav_mono.py 图片资源/m1.wav  sd960/M1.WAV
    python tools/make_wav_mono.py 图片资源      F:\\          # 整个目录 -> 卡根目录
"""

import os
import struct
import sys
import wave
from array import array

RATE = 48000
CHUNK = 1 << 20          # 每次处理 1M 帧，内存可控


def conv_one(src, dst, verbose=True):
    w = wave.open(src, "rb")
    ch = w.getnchannels()
    sw = w.getsampwidth()
    sr = w.getframerate()
    n = w.getnframes()
    if verbose:
        print("  源: %d ch / %d bit / %d Hz / %d 帧 (%.1f s)"
              % (ch, sw * 8, sr, n, n / float(sr)))
    if sw != 2:
        raise SystemExit("只支持 16bit PCM：%s 是 %dbit" % (src, sw * 8))
    if sr != RATE and verbose:
        print("  ! 采样率 %d != %d：不重采样，请自行确认素材" % (sr, RATE))

    out = wave.open(dst, "wb")
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(RATE)

    done = 0
    while done < n:
        m = min(CHUNK, n - done)
        raw = w.readframes(m)
        a = array("h")
        a.frombytes(raw)
        if ch == 2:
            l = a[0::2]
            r = a[1::2]
            mono = array("h", [((x + y) >> 1) for x, y in zip(l, r)])
        elif ch == 1:
            mono = a
        else:
            raise SystemExit("不支持的声道数 %d" % ch)
        out.writeframes(mono.tobytes())
        done += m
        if verbose:
            sys.stdout.write("\r  转换 %d%%" % (done * 100 // n))
            sys.stdout.flush()
    out.close()
    w.close()
    if verbose:
        print("\r  完成: %s  %d 字节 (%.1f s)"
              % (os.path.basename(dst), os.path.getsize(dst), n / float(RATE)))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    if os.path.isdir(src):
        os.makedirs(dst, exist_ok=True)
        for f in sorted(os.listdir(src)):
            if f.lower().endswith(".wav"):
                stem = os.path.splitext(f)[0].upper()[:8] or "TRK"
                print(f)
                conv_one(os.path.join(src, f), os.path.join(dst, stem + ".WAV"))
    else:
        conv_one(src, dst)
    return 0


if __name__ == "__main__":
    sys.exit(main())
