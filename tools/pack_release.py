# -*- coding: utf-8 -*-
"""把可交付的最小项目文件集复制到新文件夹，并打成 zip。

用法： python tools/pack_release.py [目标根目录]
默认输出 D:/Work/fpga/yuanshen/dist/声影相框_精简包_<日期>/
"""
import os
import shutil
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATE = time.strftime("%Y%m%d")
NAME = f"声影相框_精简包_{DATE}"
DEST_ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "dist")
DEST = os.path.join(DEST_ROOT, NAME)

RULES = [
    ("rtl", ("*.v",), True),
    ("constraints", ("*.adc", "*.sdc"), False),
    ("prj", ("*.al",), False),
    ("sim", ("*.v", "*.bat"), False),
    ("tools", ("*.py", "*.bat", "*.ps1"), False),
    ("docs", ("*.md", "*.docx"), False),
    ("docs/fig", ("*.png",), False),
    ("bit", ("*.bit",), False),
    ("sd_card", ("*.BMP",), False),
]
ROOT_FILES = ["赛题要求.txt"]


def copy_rule(sub, patterns, recursive):
    SRC_MAP = {"bit": "out", "sd_card": "sd960"}
    src_dir = os.path.join(ROOT, SRC_MAP.get(sub, sub))
    if not os.path.isdir(src_dir):
        print("  skip(缺失)", sub)
        return 0
    dst_dir = os.path.join(DEST, sub)
    os.makedirs(dst_dir, exist_ok=True)
    n = 0
    for pat in patterns:
        if recursive:
            for dirpath, _dirs, files in os.walk(src_dir):
                for f in files:
                    if f.lower().endswith(pat.lstrip("*").lower()):
                        rel = os.path.relpath(os.path.join(dirpath, f), src_dir)
                        t = os.path.join(dst_dir, rel)
                        os.makedirs(os.path.dirname(t), exist_ok=True)
                        shutil.copy2(os.path.join(dirpath, f), t)
                        n += 1
        else:
            for f in sorted(os.listdir(src_dir)):
                if f.lower().endswith(pat.lstrip("*").lower()):
                    shutil.copy2(os.path.join(src_dir, f), os.path.join(dst_dir, f))
                    n += 1
    print(f"  {sub}: {n} 个文件")
    return n


README = """# 声影相框 —— 基于安路 EG4S20 的 HDMI 音乐相框

精简工程包（{date}）。本包只保留**能重建、能上板、能答辩**的最小文件集，
日志、仿真工作目录、临时波形与音视频大文件均已剔除。

## 一、目录说明

| 目录 / 文件 | 内容 | 是否必需 |
| --- | --- | --- |
| `rtl/` | 全部自研 RTL（17 个功能模块，约 8 000 行 Verilog） | 必需 |
| `constraints/` | 引脚约束 `board.adc` 与时序约束 `*.sdc` | 必需 |
| `prj/yuanshen_hdmi.al` | TD 工程文件（器件、源文件列表、编译选项） | 必需 |
| `sim/` | 20+ 个测试台与批处理（`run_*.bat`），不含 work 目录 | 调试用 |
| `tools/` | 图片/音频转换、仿真批处理、报告配图与打包脚本 | 辅助 |
| `docs/` | 25 篇设计文档 + 《作品报告_音乐相框.docx》 + 配图 | 答辩用 |
| `bit/*.bit` | 已综合布线的码流，可直接烧 Flash | 上板用 |
| `sd_card/` | 已转好的 5 张 960×540 BMP，拷到卡根目录即可 | 可选 |
| `赛题要求.txt` | 赛题原始要求 | 参考 |

## 二、从源码重建

```bat
:: 综合（约 40 s）
cd prj\\yuanshen_hdmi_Runs\\syn_1
E:\\TD\\bin\\td_commands_prompt.exe yuanshen_hdmi.tcl

:: 布局布线（约 90~280 s）
cd ..\\phy_1
E:\\TD\\bin\\td_commands_prompt.exe yuanshen_hdmi.tcl
```

产物：`prj/yuanshen_hdmi_Runs/phy_1/yuanshen_hdmi.bit`。
也可以直接用 TD 图形界面打开 `prj/yuanshen_hdmi.al`，点「综合 → 布局布线 → 生成码流」。
**注意：不要在 GUI 里改布局参数**，GUI 保存工程会把 `phy_1` 的 tcl 重置成默认模板；
本工程已压缩寄存器位宽，默认脚本即可布通。

资源占用：LUT 14 888 / 19 600（76.0%）、FF 8 699、BRAM 31 / 64；
时序：clk_pix 同域 +1.3 ns 以上、clk_sd +15 ns，均无违例。

## 三、上板

1. 把 `sd_card/*.BMP` 拷到 SD 卡**根目录**（FAT32，8.3 大写短名）；
   音乐需单声道 48 kHz/16 bit WAV，用 `tools/make_wav_mono.py 源.wav sd_card/M1.WAV` 生成。
2. 卡插入板载卡座，HDMI 接显示器，上电。
3. 烧录：TD → 下载 → 选 `bit/*.bit` → 目标选 **Flash** → 擦除后写入 → 断电重上电。

上电自检：约 2 s 出第一张图。六位数码管静止时显示
`加载次数 | 出错状态 | 图片数 | 音乐数`（十六进制），例如 `1 0 0 5 0 2`
= 1 次加载无错、5 张图、2 首音乐；加载过程中前两位变为 `00~99` 进度。

## 四、仿真

```bat
cd sim
run_fat.bat            :: FAT32 簇链 + 目录扫描 + 故障注入
run_frame_full.bat     :: 帧缓存全帧写入/读出
run_osd.bat            :: 菜单 48 项断言
run_menu_fade.bat      :: 菜单淡入淡出逐帧轨迹
```

## 五、关键参数

| 项目 | 值 |
| --- | --- |
| 器件 | 安路 EG4S20BG256（康芯 HX4S20C 板） |
| 输出 | 1280×720 @ 30 Hz，HDMI 1.4b，含音频数据岛 |
| 时钟 | clk_sd 25 MHz / clk_mem 125 MHz / clk_pix 37.5 MHz |
| 帧缓存 | 960×540 RGB565 双缓冲，2.07 MB |
| 单张切图 | 1.3 s（清屏 35 ms + 读图 1.0 s + 淡入 270 ms） |
| 音频 | 48 kHz / 16 bit 单声道，嵌入 HDMI |
| 交互 | 4 键（A2↑ B2↓ B1 菜单 C1 列表）+ 4 页 OSD 菜单 |

## 六、未包含（及其再生方式）

| 未包含 | 原因 | 再生方式 |
| --- | --- | --- |
| `prj/**/*_Runs/` 日志与中间文件 | 60 MB，可重新生成 | 跑一次综合/布线 |
| `sim/` 的 work、qdb、波形、ppm | 170 MB，一次仿真即生成 | 跑对应 `run_*.bat` |
| WAV 音乐（M1/M2，共 50 MB） | 体积大 | `tools/make_wav_mono.py` 从源 wav 转 |
| `图片资源/` 原始素材 | 5 MB 源图 | `tools/make_960x540.py 图片资源 sd960` |
"""


def main():
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)
    os.makedirs(DEST, exist_ok=True)

    total = 0
    for sub, pats, rec in RULES:
        total += copy_rule(sub, pats, rec)

    for f in ROOT_FILES:
        s = os.path.join(ROOT, f)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(DEST, f))
            total += 1

    with open(os.path.join(DEST, "README.md"), "w", encoding="utf-8") as fp:
        fp.write(README.format(date=DATE))
    total += 1

    # 统计
    size = 0
    for dirpath, _d, files in os.walk(DEST):
        for f in files:
            size += os.path.getsize(os.path.join(dirpath, f))

    # 打包
    zpath = os.path.join(DEST_ROOT, NAME + ".zip")
    if os.path.exists(zpath):
        os.remove(zpath)
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dirpath, _d, files in os.walk(DEST):
            for f in files:
                p = os.path.join(dirpath, f)
                z.write(p, os.path.join(NAME, os.path.relpath(p, DEST)))

    print(f"\n文件数 {total}，解压后 {size/1048576:.1f} MB")
    print(f"目录   {DEST}")
    print(f"压缩包 {zpath}  ({os.path.getsize(zpath)/1048576:.1f} MB)")


if __name__ == "__main__":
    main()
