#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
make_fat32_image.py —— 生成一个真 FAT32 磁盘镜像，用来验证 RTL 的 FAT 解析

  · 有 MBR 分区表（和 Windows 格式化的卡一样）
  · 512B/扇区、8 扇区/簇（4KB）、2 个 FAT、根目录在簇 2
  · 根目录放 *.BMP / *.WAV，短名 8.3（RTL 目前只认 8.3）

用法:
    python tools/make_fat32_image.py                 # 默认：图片资源里的 3 张 BMP + 2 段测试 WAV
    python tools/make_fat32_image.py -o fat.img
"""

import os
import sys
import struct
import math

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECTOR = 512
SPC = 8                      # 扇区/簇
PART_LBA = 2048
RESERVED = 32
NFAT = 2


def wav_bytes(seconds=1.0, freq=440.0, sr=48000):
    """生成一段 16bit 单声道 48kHz 的 WAV（正弦）"""
    import math as m
    n = int(seconds * sr)
    pcm = bytearray()
    for i in range(n):
        v = int(12000 * m.sin(2 * m.pi * freq * i / sr))
        pcm += struct.pack('<h', v)
    hdr = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVE'
    hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr * 2, 2, 16)
    hdr += b'data' + struct.pack('<I', len(pcm))
    return bytes(hdr) + bytes(pcm)


def bmp24(w, h, tag):
    """生成 24bit 未压缩 BMP（自底向上），带渐变和方块，便于逐字节比对"""
    row = (w * 3 + 3) & ~3
    body = bytearray()
    for y in range(h - 1, -1, -1):
        line = bytearray()
        for x in range(w):
            b = (x * 255 // max(1, w - 1)) & 0xFF
            g = (y * 255 // max(1, h - 1)) & 0xFF
            r = (tag * 40 + ((x >> 5) ^ (y >> 5)) * 30) & 0xFF
            line += bytes((b, g, r))
        line += b'\x00' * (row - len(line))
        body += line
    hdr = b'BM' + struct.pack('<IHHI', 54 + len(body), 0, 0, 54)
    hdr += struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, len(body), 2835, 2835, 0, 0)
    return hdr + bytes(body)


def short_name(name):
    """8.3 短名：大写，不足补空格"""
    base, ext = os.path.splitext(name)
    base = base.upper().replace(' ', '_')[:8].ljust(8)
    ext = ext.replace('.', '').upper()[:3].ljust(3)
    return (base + ext).encode('ascii')


def build(files, out_path, exp_dir):
    """
    files: [(8.3 名字, 数据 bytes)]
    exp_dir: 把每份文件/ PCM 原样 dump 出来给 TB 逐字节比对
    """
    nclust = 3                                    # 2 = 根目录, 3.. 给文件
    plan = []
    for name, data in files:
        c = max(1, math.ceil(len(data) / (SECTOR * SPC)))
        plan.append((name, data, nclust, c))
        nclust += c
    total_clusters = nclust + 8

    fatsz = math.ceil((total_clusters + 2) * 4 / SECTOR)
    fatsz = (fatsz + SPC - 1) // SPC * SPC        # 对齐到簇，看着更像真卡
    data_lba = PART_LBA + RESERVED + NFAT * fatsz
    total_sectors = data_lba + total_clusters * SPC
    total_sectors = (total_sectors + PART_LBA + 7) // 8 * 8

    img = bytearray(total_sectors * SECTOR)

    # ---------------- MBR ----------------
    mbr = bytearray(SECTOR)
    pe = 446
    mbr[pe + 0] = 0x00
    mbr[pe + 4] = 0x0C                            # FAT32 LBA
    struct.pack_into('<I', mbr, pe + 8, PART_LBA)
    struct.pack_into('<I', mbr, pe + 12, total_sectors - PART_LBA)
    mbr[510] = 0x55
    mbr[511] = 0xAA
    img[0:SECTOR] = mbr

    # ---------------- BPB ----------------
    bpb = bytearray(SECTOR)
    bpb[0:3] = b'\xEB\x58\x90'
    bpb[3:11] = b'MSDOS5.0'
    struct.pack_into('<H', bpb, 11, SECTOR)
    bpb[13] = SPC
    struct.pack_into('<H', bpb, 14, RESERVED)
    bpb[16] = NFAT
    struct.pack_into('<H', bpb, 17, 0)            # root entries = 0 (FAT32)
    struct.pack_into('<H', bpb, 19, 0)
    bpb[21] = 0xF8
    struct.pack_into('<H', bpb, 22, 0)
    struct.pack_into('<H', bpb, 24, 63)
    struct.pack_into('<H', bpb, 26, 255)
    struct.pack_into('<I', bpb, 28, PART_LBA)
    struct.pack_into('<I', bpb, 32, total_sectors - PART_LBA)
    struct.pack_into('<I', bpb, 36, fatsz)
    struct.pack_into('<H', bpb, 40, 0)
    struct.pack_into('<H', bpb, 42, 0)
    struct.pack_into('<I', bpb, 44, 2)            # 根目录簇
    struct.pack_into('<H', bpb, 48, 1)            # FSInfo
    struct.pack_into('<H', bpb, 50, 6)            # 备份引导扇区
    bpb[64] = 0x80
    bpb[66] = 0x29
    struct.pack_into('<I', bpb, 67, 0x20261027)
    bpb[71:82] = b'NO NAME    '
    bpb[82:90] = b'FAT32   '
    bpb[510] = 0x55
    bpb[511] = 0xAA
    img[PART_LBA * SECTOR:(PART_LBA + 1) * SECTOR] = bpb

    # ---------------- FSInfo ----------------
    fsi = bytearray(SECTOR)
    struct.pack_into('<I', fsi, 0, 0x41615252)
    struct.pack_into('<I', fsi, 484, 0x61417272)
    struct.pack_into('<I', fsi, 488, 0xFFFFFFFF)
    struct.pack_into('<I', fsi, 492, 0xFFFFFFFF)
    struct.pack_into('<I', fsi, 508, 0xAA550000)
    img[(PART_LBA + 1) * SECTOR:(PART_LBA + 2) * SECTOR] = fsi

    # ---------------- FAT ----------------
    fat = bytearray(fatsz * SECTOR)
    struct.pack_into('<I', fat, 0, 0x0FFFFFF8)
    struct.pack_into('<I', fat, 4, 0x0FFFFFFF)
    for _name, _data, start, cnt in plan:
        for k in range(cnt):
            nxt = 0x0FFFFFFF if k == cnt - 1 else start + k + 1
            struct.pack_into('<I', fat, (start + k) * 4, nxt)
    struct.pack_into('<I', fat, 2 * 4, 0x0FFFFFFF)   # 根目录 1 个簇

    for f in range(NFAT):
        lba = PART_LBA + RESERVED + f * fatsz
        img[lba * SECTOR:(lba + fatsz) * SECTOR] = fat

    # ---------------- 根目录 ----------------
    def dirent(name, clus, size):
        e = bytearray(32)
        e[0:11] = short_name(name)
        e[11] = 0x20
        struct.pack_into('<H', e, 20, (clus >> 16) & 0xFFFF)
        struct.pack_into('<H', e, 26, clus & 0xFFFF)
        struct.pack_into('<I', e, 28, size)
        return bytes(e)

    root = bytearray(SPC * SECTOR)
    off = 0
    for name, data, start, cnt in plan:
        root[off:off + 32] = dirent(name, start, len(data))
        off += 32
    img[data_lba * SECTOR:(data_lba + SPC) * SECTOR] = root

    # ---------------- 文件数据 ----------------
    for name, data, start, cnt in plan:
        lba = data_lba + (start - 2) * SPC
        img[lba * SECTOR:lba * SECTOR + len(data)] = data

    open(out_path, 'wb').write(img)

    # ---------------- 给 TB 的期望数据 ----------------
    os.makedirs(exp_dir, exist_ok=True)
    for i, (name, data, start, cnt) in enumerate(plan):
        base = os.path.join(exp_dir, 'exp_%02d.bin' % i)
        open(base, 'wb').write(data)
        # WAV 额外 dump 纯 PCM（跳过 44 字节头）
        if name.upper().endswith('.WAV'):
            open(os.path.join(exp_dir, 'exp_%02d.pcm' % i), 'wb').write(data[44:])

    print('image : %s (%.1f MB)' % (out_path, len(img) / 1048576.0))
    print('part  : LBA %d, reserved %d, FAT %d 扇区 x%d, data LBA %d, %d 扇区/簇'
          % (PART_LBA, RESERVED, fatsz, NFAT, data_lba, SPC))
    print('files : %d' % len(plan))
    for i, (name, data, start, cnt) in enumerate(plan):
        print('  [%d] %-12s %8d B  cluster %3d..%3d  (%d 簇)'
              % (i, name, len(data), start, start + cnt - 1, cnt))
    return plan


def main():
    out = os.path.join(ROOT, 'sim', 'fat_card.img')
    exp = os.path.join(ROOT, 'sim', 'fat_exp')
    files = []

    # 测试用 BMP 故意做小（几十 KB），这样仿真能在几秒内跑完整条簇链；
    # 尺寸/内容与真实 1280x720 图走的是完全相同的代码路径。
    files.append(('IMG1.BMP', bmp24(320, 240, 1)))
    files.append(('IMG2.BMP', bmp24(160, 120, 2)))
    files.append(('IMG3.BMP', bmp24(240, 180, 3)))
    files.append(('T1.WAV', wav_bytes(1.0, 440.0)))
    files.append(('T2.WAV', wav_bytes(1.0, 660.0)))

    build(files, out, exp)


if __name__ == '__main__':
    main()
