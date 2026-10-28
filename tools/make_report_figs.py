# -*- coding: utf-8 -*-
"""作品报告配图：按 A4 正文宽 14.5 cm 反推画布尺寸，保证缩印后字号仍有 7~9 pt。
   逻辑画布 620 px 宽 -> 打印 145 mm，1 px ≈ 0.234 mm，13 px ≈ 3.0 mm ≈ 8.7 pt。"""
import os
import math
from PIL import Image, ImageDraw, ImageFont

FONT = "C:/Windows/Fonts/simhei.ttf"
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs", "fig")
os.makedirs(OUT, exist_ok=True)
S = 5            # 内部超采样
SAVE_MUL = 3     # 输出 = 逻辑尺寸 x3（约 400 dpi）

PAL = {
    "in":    ("#FFF3E6", "#C05621", "#7B341E"),
    "sd":    ("#E7F6EF", "#1F7A5C", "#14503B"),
    "proc":  ("#E8F0FB", "#2B5C9E", "#173D6B"),
    "mem":   ("#F1EAFB", "#6B46C1", "#3C1E70"),
    "disp":  ("#FDECEC", "#B02A2A", "#6B1B1B"),
    "ctrl":  ("#EEF1F5", "#4A5568", "#1A202C"),
    "aud":   ("#FFF8DA", "#B7791F", "#6B4A0F"),
}
INK = "#1A202C"
GREY = "#334155"


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.im = Image.new("RGB", (w * S, h * S), "white")
        self.d = ImageDraw.Draw(self.im)
        self.cache = {}

    def font(self, size):
        k = int(round(size * S))
        if k not in self.cache:
            self.cache[k] = ImageFont.truetype(FONT, k)
        return self.cache[k]

    def tw(self, s, size):
        return self.d.textlength(s, font=self.font(size)) / S

    def title(self, cx, y, s, size=16, fill="#0F172A"):
        self.d.text((cx * S, y * S), s, font=self.font(size), fill=fill, anchor="mm")

    def _fit(self, s, size, maxw, floor=8):
        while size > floor and self.tw(s, size) > maxw:
            size -= 0.5
        return size

    def rbox(self, x0, y0, x1, y1, head, subs=None, kind="proc", r=5, lw=1.4,
             tsize=13, pad=6, gap=2):
        fill, line, tcol = PAL[kind]
        self.d.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=r * S,
                                 fill=fill, outline=line, width=int(lw * S))
        W = (x1 - x0) - 2 * pad
        subs = subs or []
        hs = self._fit(head, tsize, W, 9)
        ss = hs - 2.5
        if subs:
            ss = min(ss, min(self._fit(t, ss, W, 7) for t in subs))
        lh = ss * 1.55
        total = hs * 1.3 + len(subs) * lh
        top = (y0 + y1) / 2 - total / 2
        self.d.text(((x0 + x1) / 2 * S, (top + hs * 0.62) * S), head,
                    font=self.font(hs), fill=tcol, anchor="mm")
        y = top + hs * 1.3 + lh * 0.55
        for t in subs:
            self.d.text(((x0 + x1) / 2 * S, y * S), t, font=self.font(ss),
                        fill=INK, anchor="mm")
            y += lh

    def band(self, y0, y1, name, x0=8, x1=62, size=10):
        self.d.rounded_rectangle([x0 * S, y0 * S, x1 * S, y1 * S], radius=4 * S,
                                 fill="#F7F9FC", outline="#CBD5E1", width=S)
        # 竖排
        n = len(name)
        fh = size
        step = (y1 - y0 - 8) / max(n, 1)
        for i, ch in enumerate(name):
            self.d.text(((x0 + x1) / 2 * S, (y0 + 4 + step * (i + 0.5)) * S), ch,
                        font=self.font(min(fh, step * 0.9)), fill=GREY, anchor="mm")

    def arrow(self, pts, color=GREY, w=1.3, head=4.5, dash=False):
        seq = [(p[0] * S, p[1] * S) for p in pts]
        for i in range(len(seq) - 1):
            a, b = seq[i], seq[i + 1]
            if dash:
                self._dash(a, b, color, w)
            else:
                self.d.line([a, b], fill=color, width=max(1, int(w * S)))
        (ax, ay), (bx, by) = seq[-2], seq[-1]
        ang = math.atan2(by - ay, bx - ax)
        L = head * S
        self.d.polygon([(bx, by),
                        (bx - L * math.cos(ang - 0.45), by - L * math.sin(ang - 0.45)),
                        (bx - L * math.cos(ang + 0.45), by - L * math.sin(ang + 0.45))],
                       fill=color)

    def _dash(self, a, b, color, w, seg=4, gap=3):
        dx, dy = b[0] - a[0], b[1] - a[1]
        d = math.hypot(dx, dy)
        if d == 0:
            return
        ux, uy = dx / d, dy / d
        t = 0
        while t < d:
            e = min(t + seg * S, d)
            self.d.line([(a[0] + ux * t, a[1] + uy * t),
                         (a[0] + ux * e, a[1] + uy * e)], fill=color,
                        width=max(1, int(w * S)))
            t = e + gap * S

    def note(self, cx, y, s, size=9.5, fill=GREY, anchor="mm"):
        self.d.text((cx * S, y * S), s, font=self.font(size), fill=fill, anchor=anchor)

    def save(self, name):
        p = os.path.join(OUT, name)
        self.im.resize((int(self.w * SAVE_MUL), int(self.h * SAVE_MUL)),
                       Image.LANCZOS).save(p, dpi=(400, 400))
        print("saved", name, (self.w, self.h))


# =====================================================================
def fig_flow():
    c = Canvas(620, 268)
    c.title(310, 13, "图 1  作品设计流程")
    st = [
        ("① 需求分解", "5 项扩展要求\n场景定义", "in"),
        ("② 架构设计", "时钟域 / 带宽\n容量核算", "proc"),
        ("③ RTL 编码", "17 个功能模块\nvalid-ready", "proc"),
        ("④ 仿真验证", "12 个测试台\n故障注入", "sd"),
        ("⑤ 综合实现", "TD 命令行\n资源时序", "mem"),
        ("⑥ 布局布线", "pib 冲突定位\n位宽压缩", "mem"),
        ("⑦ 上板联调", "6 位数码管\n逻辑分析仪", "disp"),
        ("⑧ 迭代收敛", "25 篇文档\n回归固化", "ctrl"),
    ]
    W, H = 143, 70
    for i, (t, s, k) in enumerate(st):
        row, col = divmod(i, 4)
        x, y = 8 + col * 154, 32 + row * 104
        c.rbox(x, y, x + W, y + H, t, s.split("\n"), k, tsize=12)
        if col < 3:
            c.arrow([(x + W + 1, y + H / 2), (x + W + 10, y + H / 2)], head=4)
    c.arrow([(541, 103), (541, 122), (79, 122), (79, 136)], color="#B02A2A", head=4)
    c.note(330, 112, "阶段评审不达标则回退", 8.6, "#B02A2A")
    c.arrow([(541, 207), (541, 232), (79, 232), (79, 207)],
            color="#B02A2A", head=4, dash=True)
    c.note(310, 248, "上板问题反向驱动 RTL 修改（共 9 轮迭代）", 8.6, "#B02A2A")
    c.save("fig1_flow.png")


# =====================================================================
def fig_arch():
    c = Canvas(620, 404)
    c.title(310, 13, "图 2  系统总体框图")

    bands = [("输入层", 30, 88), ("读取层", 96, 154), ("处理层", 162, 220),
             ("缓存层", 228, 286), ("输出层", 294, 352)]
    for n, y0, y1 in bands:
        c.band(y0, y1, n)

    rows = [
        [("SD 卡（FAT32）", ["根目录 8.3 短名", "插卡即用"], "in"),
         ("4 个独立按键", ["A2↑ B2↓ B1 菜单", "C1 列表"], "in"),
         ("50 MHz 晶振 + PLL", ["5 路时钟输出", "像素域 37.5 MHz"], "in")],
        [("SD 命令层", ["sd_init / sd_read / sd_arb", "SPI 25 MHz，CMD17"], "sd"),
         ("FAT32 解析", ["MBR→BPB→目录→簇链", "图片 / 音乐数量自适应"], "sd"),
         ("资源读取", ["bmp_reader：字节流", "wav_player：data 块"], "sd")],
        [("BMP 解码 + 缩放", ["任意分辨率 → 960×540", "24/32/8 bit → RGB565"], "proc"),
         ("异步 FIFO 跨域", ["25 MHz → 125 MHz", "256 深 × 24 bit"], "proc"),
         ("WAV 播放 + 频谱", ["Goertzel 32 段", "条形 / 圆形两种样式"], "aud")],
        [("帧缓存控制器", ["写 4 字突发 / 读行 FIFO", "丢字与饥饿统计"], "mem"),
         ("SDRAM  2M×32", ["双缓冲 A/B 乒乓", "每帧 1,036,800 B"], "mem"),
         ("读侧 4:3 上采样", ["960×540 → 1280×720", "精确抽取，无插值"], "mem")],
        [("转场 + OSD 叠加", ["FADE/SLIDE/WIPE/CUT", "菜单淡入淡出"], "disp"),
         ("视频打包 + HDMI", ["rgb2axis → TMDS", "727.5 Mb/s × 3"], "disp"),
         ("HDMI 输出", ["1280×720 @30 Hz", "+ 48 kHz 音频数据岛"], "disp")],
    ]
    xs = [(68, 246), (252, 430), (436, 614)]
    for r, row in enumerate(rows):
        y0 = 32 + r * 66
        for cidx, (t, subs, k) in enumerate(row):
            x0, x1 = xs[cidx]
            c.rbox(x0, y0, x1, y0 + 54, t, subs, k, tsize=12)
            if cidx < 2:
                c.arrow([(x1 + 1, y0 + 27), (x1 + 5, y0 + 27)], head=3.6)
    # 层间竖向数据流
    for r in range(4):
        y0 = 32 + r * 66 + 54
        c.arrow([(66, y0 + 1), (66, y0 + 9)], color="#0F766E", head=3.4)
    c.note(310, 372, "层间为数据流方向：SD 字节流 → 解码缩放 → 帧缓存 → 读出叠加 → HDMI 发送", 9)
    c.note(310, 390, "控制通路（按键、参数、菜单）与数据通路分离，参数在帧首单拍统一提交", 9)
    c.save("fig2_arch.png")


# =====================================================================
def fig_pipe():
    c = Canvas(620, 250)
    c.title(310, 13, "图 3  图像数据通路与跨时钟域")

    zones = [(6, 210, "#F4FBF7", "#1F7A5C", "clk_sd 25 MHz"),
             (216, 330, "#FFFDF3", "#B7791F", "跨时钟域"),
             (336, 470, "#F7F4FD", "#6B46C1", "clk_mem 125 MHz"),
             (476, 614, "#FEF5F5", "#B02A2A", "clk_pix 37.5 MHz")]
    for x0, x1, fill, line, name in zones:
        c.d.rounded_rectangle([x0 * S, 46 * S, x1 * S, 146 * S], radius=6 * S,
                              fill=fill, outline=None)
        w = c.tw(name, 9.5) / 2 + 7
        cx = (x0 + x1) / 2
        c.d.rounded_rectangle([(cx - w) * S, 34 * S, (cx + w) * S, 48 * S],
                              radius=7 * S, fill="white", outline=line, width=S)
        c.d.text((cx * S, 41 * S), name, font=c.font(9.5), fill=line, anchor="mm")

    c.rbox(12, 52, 118, 138, "sd_bmp_reader", ["簇链 → 扇区", "8 bit 字节流"], "sd", tsize=11)
    c.rbox(126, 52, 204, 138, "BMP 解码", ["24 → 16 bit", "逐行取点"], "proc", tsize=11)
    c.rbox(222, 52, 324, 138, "异步 FIFO", ["写 25 MHz", "读 125 MHz"], "aud", tsize=11)
    c.rbox(342, 52, 464, 138, "写组装 + 帧缓存", ["4 字突发", "写 FIFO 256 深"], "mem", tsize=11)
    c.rbox(482, 52, 608, 138, "读 FIFO + 上采样", ["4:3 抽取", "→ 1280×720"], "disp", tsize=11)

    c.rbox(342, 160, 464, 204, "SDRAM  2M×32", ["写 A 读 B，帧末切换"], "mem", tsize=11)
    c.arrow([(403, 140), (403, 158)], color="#6B46C1", head=3.6)
    c.arrow([(545, 140), (545, 156)], color="#B02A2A", head=3.6)
    c.note(545, 166, "→ 转场 → OSD → HDMI", 8.4, "#B02A2A")

    for x0, x1 in [(119, 125), (205, 221), (325, 341), (465, 481)]:
        c.arrow([(x0, 95), (x1, 95)], head=3.4)

    c.note(310, 226, "带宽：写侧限速 1 次 / 64 拍 ≈ 7.8 M 字/s，读侧仅占 9%，可边读图边显示", 9)
    c.note(310, 242, "实测：960×540（约 2030 个扇区）载入 1.3 s，清屏 35 ms，淡入 270 ms", 9)
    c.save("fig3_pipe.png")


# =====================================================================
def fig_fsm():
    c = Canvas(620, 300)
    c.title(310, 13, "图 4  图片加载状态机与超时自愈")

    y, h = 28, 40
    st = [("LD_WAIT", "等卡就绪"), ("LD_CLEAR", "写黑 35 ms"), ("LD_ARM", "切写 bank"),
          ("LD_LOAD", "读图 + 写缓存"), ("LD_SHOW", "显示 / 轮播")]
    xs = [(8, 112), (128, 240), (256, 344), (360, 476), (492, 612)]
    for i, (n, s) in enumerate(st):
        x0, x1 = xs[i]
        c.rbox(x0, y, x1, y + h, n, [s], "proc" if i in (1, 2) else
               ("mem" if i == 3 else ("disp" if i == 4 else "ctrl")), tsize=11)
        if i < 4:
            c.arrow([(x1 + 1, y + 20), (xs[i + 1][0] - 1, y + 20)], head=3.4)
    c.arrow([(552, y + h + 1), (552, 82), (60, 82), (60, y + h + 1)], color="#B02A2A", head=3.4)
    c.note(310, 76, "切图请求 / 轮播到时 / 自愈重试", 8.4, "#B02A2A")

    c.note(310, 96, "sd_bmp_reader 内部：每个等待都有超时退路", 9.5, GREY)
    sub = [("S_IDLE", "等 en"), ("S_TBL", "读表项 21 ms"), ("S_CMD", "先等 !rd_busy"),
           ("S_RCV", "收 256 字 21 ms"), ("S_GAP", "等写 FIFO"), ("S_F0~F2", "跟簇链/判结束")]
    sx = [(8, 100), (108, 200), (208, 308), (316, 424), (432, 508), (516, 612)]
    for i, (n, s) in enumerate(sub):
        x0, x1 = sx[i]
        c.rbox(x0, 106, x1, 154, n, [s], "sd" if i < 5 else "proc", tsize=10)
        if i < 5:
            c.arrow([(x1 + 1, 130), (sx[i + 1][0] - 1, 130)], head=3)
    c.arrow([(564, 155), (564, 172), (52, 172), (52, 155)], color="#B02A2A", head=3)
    c.note(330, 166, "done / err 上报顶层", 8.2, "#B02A2A")

    c.d.rounded_rectangle([8 * S, 186 * S, 612 * S, 292 * S], radius=5 * S,
                          fill="#FFF8F8", outline="#B02A2A", width=S)
    c.d.text((14 * S, 197 * S), "超时与自愈", font=c.font(10.5), fill="#B02A2A", anchor="lm")
    lines = [
        "① 命令阶段 21 ms 等不到 R1 响应 → 撤请求退出，避免整条 SPI 总线被一次异常永久占用；",
        "② 收数阶段 21 ms 未收满 256 字 → 直接判失败，不重试（半截数据会让整幅图错行约 200 字节）；",
        "③ 顶层 ld_tmo（3.4 s 电平）超时 → 复位 SD 段，回 LD_WAIT 重挂载、重扫描、重读一次；",
        "④ 第二次仍失败 → 保留上一张画面收工，绝不黑屏或花屏；",
        "⑤ 进度只在「新一次切图」那拍清零，加载中绝不清零，0→99 只走一次。",
    ]
    yy = 209
    for t in lines:
        c.d.text((14 * S, yy * S), t, font=c.font(8.8), fill=INK, anchor="lm")
        yy += 15
    c.save("fig4_fsm.png")


if __name__ == "__main__":
    fig_flow()
    fig_arch()
    fig_pipe()
    fig_fsm()
