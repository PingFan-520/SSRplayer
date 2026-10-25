#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_demo_wavs.py —— 合成 4 首演示用 WAV（单声道 16bit 48kHz）

为什么自己合成：
    仓库里不能带版权音乐；而"从 SD 播放 WAV"这条路需要一个能直接用的素材。
    这里用纯 Python 合成几段风格不同的短曲（12~16 秒），
    正好覆盖演示需要的"有节奏、有强弱、有高低"的动态，电平表才会好看。

规格（必须与 HDMI 的 ACR 一致）：
    48000 Hz / 16 bit / 单声道 —— 每 16bit SD 字正好一个采样，RTL 不用拆包

用法: python tools/make_demo_wavs.py
输出: 音乐资源/*.wav
"""

import os
import math
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "音乐资源")

SR = 48000


def env_ad(n, attack, decay):
    """简单 AD 包络：线性起音 + 指数衰减"""
    if n < attack:
        return n / float(attack)
    return math.exp(-(n - attack) / float(decay))


def note_hz(semi):
    """半音索引 -> 频率（0 = A3 = 220Hz）"""
    return 220.0 * (2.0 ** (semi / 12.0))


def render(notes, bpm, wave_mix=(1.0, 0.35, 0.15), tail=1.2):
    """notes: [(semi, beats, amp)]，返回 int16 采样列表"""
    spb = 60.0 / bpm                      # 每拍秒数
    total = int(sum(b for _, b, _ in notes) * spb * SR + tail * SR)
    buf = [0.0] * total
    pos = 0
    for semi, beats, amp in notes:
        n = int(beats * spb * SR)
        f = note_hz(semi)
        atk = int(0.008 * SR)
        dec = max(1, int(0.35 * SR))
        for i in range(n):
            t = i / float(SR)
            a = env_ad(i, atk, dec)
            v = 0.0
            for h, g in enumerate(wave_mix, start=1):
                v += g * math.sin(2 * math.pi * f * h * t)
            v *= a * amp
            if pos + i < total:
                buf[pos + i] += v
        pos += int(beats * spb * SR)

    # 归一化到 -0.9..0.9 并加一点点淡入淡出，避免首尾爆音
    peak = max(1e-6, max(abs(x) for x in buf))
    g = 0.9 / peak
    fade = int(0.02 * SR)
    out_i = []
    for i, x in enumerate(buf):
        y = x * g
        if i < fade:
            y *= i / fade
        if i > total - fade:
            y *= (total - i) / fade
        out_i.append(int(max(-32767, min(32767, y * 32767))))
    return out_i


def write_wav(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))


# ----------------------------------------------------------------------
# 1) 温柔琶音：C - E - G - B 循环，每音两拍
# ----------------------------------------------------------------------
def t1():
    seq = []
    for base in (3, 5, 8, 10, 8, 5):           # C E G B（相对 A3 的半音）
        for k in (0, 4, 7, 12):
            seq.append((base + k, 1.0, 0.75))
    seq = seq * 2
    return render(seq, 114)          # ~17 秒


# ----------------------------------------------------------------------
# 2) 五声音阶散步（带低音）
# ----------------------------------------------------------------------
def t2():
    mel = [3, 5, 7, 10, 12, 10, 7, 5, 3, 7, 10, 12, 15, 12, 10, 7]
    seq = []
    for i, m in enumerate(mel):
        seq.append((m, 0.5, 0.65))
        seq.append((m + 12, 0.5, 0.35))
        if i % 4 == 0:
            seq.append((-9, 1.0, 0.5))          # A2 低音
    return render(seq, 100)


# ----------------------------------------------------------------------
# 3) 华尔兹（3/4：低音 + 两个和弦音）
# ----------------------------------------------------------------------
def t3():
    prog = [(3, 7, 10), (5, 8, 12), (10, 14, 17), (8, 12, 15)]
    seq = []
    for _ in range(3):
        for ch in prog:
            seq.append((ch[0] - 12, 1.0, 0.7))
            for k in ch[1:]:
                seq.append((k, 1.0, 0.4))
    return render(seq, 132, wave_mix=(1.0, 0.25, 0.1))


# ----------------------------------------------------------------------
# 4) 空灵 pad：长音和弦缓慢推进
# ----------------------------------------------------------------------
def t4():
    chords = [(3, 10, 15, 19), (5, 12, 17, 20), (0, 7, 15, 19), (3, 10, 14, 19)]
    seq = []
    for ch in chords * 2:
        for k in ch:
            seq.append((k, 2.0, 0.28))
    return render(seq, 84, wave_mix=(1.0, 0.5, 0.3, 0.15), tail=2.0)   # ~25 秒


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for i, fn in enumerate((t1, t2, t3, t4), start=1):
        data = fn()
        p = os.path.join(OUT, "track%d.wav" % i)
        write_wav(p, data)
        print("%s  %d 采样  %.1f 秒  %d 字节"
              % (os.path.basename(p), len(data), len(data) / float(SR), os.path.getsize(p)))
    print("完成：把 音乐资源/*.wav 交给 tools/make_sd_image.py 一起排进镜像")
