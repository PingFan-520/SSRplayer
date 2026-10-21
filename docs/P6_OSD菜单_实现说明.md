# P6 · OSD 调试菜单与输出级 —— 实现与集成说明

> 状态：**已实现，ModelSim 仿真通过（含截图与像素级校验）**
> 更新：2026-10-21（第二版：加入转场、亮度/对比度、滚动字幕、帧同步参数提交、上板工程）

---

## 1. 文件清单

| 文件 | 作用 | 规模（估） |
| --- | --- | --- |
| `rtl/ui/font_rom.v` | 16×16 点阵字模 ROM（62 字，`tools/gen_font.py` 生成） | 1024×16b（2×9Kb ERAM） |
| `rtl/ui/key_ctrl.v` | 4 路按键同步 / 去抖 / 长按 10Hz 连发 | ~90 LUT |
| `rtl/ui/osd_menu.v` | 菜单状态机 + 遮罩/面板/文字 + 滚动字幕条 | ~480 LUT |
| `rtl/ui/alpha_blend.v` | 8 档 alpha 混合（移位加法，0 DSP） | ~150 LUT |
| `rtl/ui/transition.v` | 转场引擎（FADE / SLIDE / WIPE / CUT）+ 自动节拍 | ~200 LUT |
| `rtl/ui/param_apply.v` | 亮度 / 对比度（输出级像素运算） | ~120 LUT |
| `rtl/ui/cfg_latch.v` | 参数影子寄存器，`cfg_commit` 帧首统一提交 | ~40 LUT |
| `rtl/video/color_bar_hd.v` | 720p 时序 + 彩条测试图（A 路） | — |
| `rtl/video/test_pattern_b.v` | 渐变 + 网格 + 移动亮条（B 路） | — |
| `rtl/video/rgb2axis.v` | RGB/DE/VS → AXIS（行宽参数化） | — |
| `rtl/top_osd_demo.v` | 双图 + 转场 + 参数 + 菜单的整合顶层 | — |
| `rtl/top_board.v` | **上板顶层**：PLL / HDMI 核 / 按键 / 数码管 | — |
| `rtl/hdmi/*` | HDMI 1.4b 发送核（加密）+ PHY 并串转换 | 厂商文件 |
| `tools/gen_td_prj.py` | 生成 TD 工程 `prj/yuanshen_hdmi.al` | — |
| `sim/tb_osd_demo.v` | 按键序列 + 全屏/面板截图导出 | — |
| `constraints/board.adc` / `board.sdc` | 上板引脚与时序约束 | — |

---

## 2. 数据通路

```
color_bar_hd (A) ─┐
                  ├─> transition ─> param_apply ─> 打 2 拍 ─┐
test_pattern_b(B) ┘                                        ├─> alpha_blend ─> rgb_out ─> rgb2axis ─> HDMI
osd_menu (遮罩/面板/字幕) ─────────────────────────────────┘
     ▲
key_ctrl ── 4 键事件
```

- 菜单输出比输入 `x/y` 晚 **2 拍**，因此视频、`hs/vs/de/x/y` 必须一起延 2 拍。
- `cfg_latch` 把菜单参数与数据面隔离：按键随时可改，**只在帧首 `cfg_commit` 生效**，避免一帧内上下半屏参数不同。
- 坐标使用**活动区坐标**（`x/y` 已减去 HSA+HBP / VSA+VBP），面板位置就是屏幕上看到的位置。

---

## 3. 接口

### 3.1 osd_menu

| 端口 | 方向 | 说明 |
| --- | --- | --- |
| `clk / rst` | in | 像素时钟域，rst 高有效 |
| `x / y` | in | 活动区像素坐标（0..HACTIVE-1 / 0..VACTIVE-1） |
| `de` | in | 数据有效（预留门控） |
| `key_menu/up/down/ok` | in | 单拍事件 |
| `osd_rgb / osd_alpha / osd_on` | out | 叠加层颜色与权重（0..8，8=不透明） |
| `menu_open` | out | 菜单是否打开 |
| `cfg_trans/bright/contrast/scale/sub/vol` | out | 参数原值（帧内可能变） |
| `cfg_commit` | out | 帧首单拍，下游在此锁存 |
| `dbg_item / dbg_val` | out | 光标项与取值（接数码管） |

### 3.2 transition

| 端口 | 说明 |
| --- | --- |
| `rgb_a / rgb_b` | 两路同坐标像素 |
| `x` | 活动区横坐标 |
| `effect` | 0=FADE 1=SLIDE 2=WIPE 3=CUT |
| `prog` | 0..255，**0 全 A，255 全 B**（四种效果一致） |
| `rgb_out` | 混合结果 |

SLIDE 的软边固定 32 像素：`split_x = HACTIVE - prog*HACTIVE/256`，边界前 A、边界后 B。
注意这是**坐标选择**，不做内容平移（真平移需要行缓冲，成本翻倍）。

### 3.3 param_apply

```
gain = 64 + 7*contrast          (contrast 0..10 → 0.50 .. 1.05)
off  = (bright - 10) * 16       (bright  0..10 → -160 .. 0)
out  = clamp( (in-128)*gain>>7 + 128 + off )
```

### 3.4 cfg_latch

`commit` 单拍时把 `in_*` 搬到 `out_*`，并给出版本号 `ver`（每提交一次 +1，接数码管可看参数是否落盘）。

### 3.5 参数编码

| 参数 | 位宽 | 取值 |
| --- | --- | --- |
| `cfg_trans` | 2 | 0=FADE 1=SLIDE 2=WIPE 3=CUT |
| `cfg_bright` | 4 | 0..10，单位 10% |
| `cfg_contrast` | 4 | 0..10，单位 10% |
| `cfg_scale` | 2 | 0=FIT 1=FILL 2=STRETCH |
| `cfg_sub` | 1 | 1=字幕开 |
| `cfg_vol` | 4 | 0..10，单位 10% |

---

## 4. 接进正式工程

1. **替换背景源**：把 `top_osd_demo` 里的 `color_bar_hd` 换成帧缓存读出口，提供 `rgb/hs/vs/de` 与活动区 `x/y`。
2. **混合位置**：`alpha_blend` 必须在 `rgb2axis` **之前**，是像素的最后一站。
3. **参数落点**：
   - `cfg_trans` → `transition.effect`（经 `cfg_latch`）；
   - `cfg_bright/contrast` → `param_apply`；
   - `cfg_scale` → 缩放器目标框（重载时生效，当前只输出）；
   - `cfg_sub` → 字幕层使能（已在 `osd_menu` 内部帧同步）；
   - `cfg_vol` → 音频增益。
4. **复位**：`rst` 高有效，与像素域同步释放。

---

## 5. 字幕条

- 位置：底部 `VACTIVE-104 .. VACTIVE-40`，条高 64px，黑色 5/8 透明。
- 文字：32px 高（16×16 点阵 2 倍），每字 32px 宽，左侧从 `x = -scroll` 开始。
- 滚动：每帧 `scroll += 3`，到 2304 回绕（约 4.6 秒一轮）。
- 内容表：`g_sub(5'd0..31)`，当前为 `NOW PLAYING 01/12  MUSIC FRAME`，换文案只改这张表。
- 开关：`cfg_sub`，帧首生效，切换时不会把一行字切成两半。

---

## 6. 上板工程

已生成 TD 工程：`prj/yuanshen_hdmi.al`（顶层 `top_board`，器件 EG4S20BG256）。

| 信号 | 引脚 | 说明 |
| --- | --- | --- |
| `clk_50m` | R7 | 板载 50MHz |
| `key1` | A2 | MENU 开合 |
| `key3` | B1 | UP |
| `key4` | B2 | DOWN |
| `key2` | C1 | OK |
| `HDMI_CLK_P` | C3 | TMDS 时钟 |
| `HDMI_D0_P/D1_P/D2_P` | G5 / F1 / E1 | TMDS 数据 |
| `HDMI_DDC_SCL/SDA` | P2 / R2 | EDID |

- 板上 4 个按键全部用上，**复位改为 PLL 锁定 + 上电计数释放**，不再占用按键。
- PLL：`FBCLK_DIV=15 / CLKC0_DIV=10 / CLKC1_DIV=2` → 75.000MHz / 375MHz（已实测）。
- 重建工程：`python tools/gen_td_prj.py`。

详见 `docs/上板测试指南.md`。

---

## 7. 仿真验证结果

命令：`sim\run_sim.bat tb_osd_demo`

| 项 | 证据 | 结果 |
| --- | --- | --- |
| 菜单开合 | `menu_closed2.png` 面板区域纯彩条 | 无残留 |
| 光标移动 | `menu_slide.png` 六行数值各自正确 | 通过 |
| 遮罩 | 白 (255,255,255) → (159,159,159) | 3/8 黑 |
| 播放不中断 | `menu_full` vs `menu_full2` 差异区域 = 每帧右移的方块 | 背景仍在刷新 |
| FADE 50% | `trans_fade.png` 彩条与渐变各半 | 通过 |
| SLIDE 37.5% | `trans_slide.png` 边界在 x≈400/640（=800/1280） | 通过 |
| WIPE 62.5% | `trans_wipe.png` 边界在 x≈240/640（=480/1280） | 通过 |
| 亮度 100%→30% | 全屏平均亮度 **119.2 → 68.7**（-42%） | 通过 |
| 字幕 OFF/ON | 条带区域消失/恢复；全屏均值 71.9 ↔ 68.7 | 通过 |
| 参数帧同步 | 数码管版本号每次改动 +1 | 通过 |

---

## 8. 资源（估算，待 TD 实测校准）

| 模块 | LUT | FF | ERAM | DSP |
| --- | --- | --- | --- | --- |
| font_rom | 40 | 0 | 2×9Kb | 0 |
| osd_menu | 480 | 280 | 0 | 0 |
| alpha_blend | 150 | 0 | 0 | 0 |
| transition | 200 | 20 | 0 | 0 |
| param_apply | 120 | 0 | 0 | 0 |
| cfg_latch | 40 | 30 | 0 | 0 |
| key_ctrl | 90 | 100 | 0 | 0 |
| **合计** | **≈1,120** | **≈430** | **2 块** | **0** |

> 若 TD 没把 `font_rom` 推成 ERAM（变成分布式 ROM 会吃掉 ~1000 LUT），改用 IP Generator 生成 ROM 并加载同一份 `.mif`。

---

## 9. 已知限制

- 面板位置/尺寸是编译期参数（`PX0/PY0/PW/PH`），运行时不可拖动；
- 文字 2 倍放大，未做抗锯齿；
- SLIDE/WIPE 是坐标切换，不做内容平移；
- `cfg_scale` 只走到参数链路，视觉切换要等 P4 缩放器；
- `cfg_vol` 尚未接音频通路（当前工程无音频）；
- 长按 OK 连发 10Hz，未做加速档。

---

## 10. 仿真输出

| 文件 | 内容 |
| --- | --- |
| `menu_closed.ppm` / `menu_open.ppm` / `menu_slide.ppm` / `menu_closed2.ppm` | 面板区域特写 |
| `menu_full.ppm` / `menu_full2.ppm` | 全屏相邻两帧（证明背景在动） |
| `trans_fade.ppm` / `trans_slide.ppm` / `trans_wipe.ppm` | 三种转场中间态 |
| `bright_base.ppm` / `bright_low.ppm` | 亮度 100% / 30% |
| `sub_off.ppm` / `sub_on.ppm` | 字幕关 / 开 |

PPM 用 Pillow 一行转 PNG：`Image.open(f).save(f[:-4]+'.png')`。

上板顶层不跑仿真，只做语法/端口检查（HDMI 加密核用 `sim/stub_hdmi_core.v` 占位）：

```bat
sim\lint_board.bat
```

输出 `LINT_OK` 即表示 `top_board` 能 elaborate 并跑 1ms。
