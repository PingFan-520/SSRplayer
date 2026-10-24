# P8 · SD 卡 BMP 轮播 —— 使用说明

> 状态：RTL 完成、lint 通过（0 error / 0 warning），待上板
> 更新：2026-10-24

---

## 1. 链路

```
SD 卡(SPI 25MHz) → sd_ctrl_top → sd_bmp_reader → 异步FIFO(8bit)
   → bmp_decode(RGB565 + 屏幕坐标) → frame_buffer → SDRAM
   → 显示侧读出 → top_osd_demo(转场/菜单) → rgb2axis → HDMI
```

| 模块 | 文件 | 作用 |
| --- | --- | --- |
| SD 协议层 | `rtl/sd/sd_init.v` `sd_read.v` `sd_ctrl_top.v` | 移植自参考工程，**改成单时钟**（用 `negedge clk_ref` 代替 180° 反相时钟） |
| 扇区读取 | `rtl/sd/sd_bmp_reader.v` | 逐扇区 CMD17 连续读，16bit → 2 字节（**先出高字节**） |
| 解码 | `rtl/video/bmp_decode.v` | 24bit 未压缩，行 4 字节对齐，自动居中 |
| 轮播控制 | `top_board.v` 内状态机 | WAIT → LOAD → SHOW → ARM → LOAD … |

时钟：PLL 新增 `CLKC4 = 25MHz` 给 SPI（`CLKC0..3` 分别给像素/HDMI串行/SDRAM/移相）。

---

## 2. 为什么用裸扇区而不是 FAT32

- 要做 FAT32 得实现 MBR/DVT 解析、簇链遍历，工作量和风险都远大于当前收益；
- 参考工程 `sd_read_photo` 也是这个策略（从固定扇区连续读）；
- 比赛演示只需要「上电自动循环播放 N 张图」。

**代价**：写镜像会覆盖卡的分区表，**这张卡之后在 Windows 里不可读**。请用一张闲置卡。

---

## 3. 制作 SD 卡

```bash
python tools/make_sd_image.py
```

默认读取 `图片资源/*.bmp`，输出 `sd_image.img`（本项目 6 张图 → 6.28MB）。

要求每张 BMP：**640×480、24bit、未压缩、`bfOffBits` 任意**（脚本会校验）。

布局：

| 项 | 值 |
| --- | --- |
| 第 0 张起始扇区 | 2048（1MB 偏移） |
| 每张占用扇区 | 1801（= 922112 字节） |
| 第 i 张起始扇区 | `2048 + i × 1801` |

写入卡：**Win32DiskImager / Rufus / balenaEtcher**，选 `sd_image.img`。

或者用项目自带的脚本（Windows，需管理员）：

```
tools\write_sd.bat    右键 -> 以管理员身份运行    # 写入（含写后校验）
tools\verify_sd.bat   右键 -> 以管理员身份运行    # 全量 SHA256 只读校验
```

### 写卡踩过的坑（重要）

| 尝试 | 结果 |
| --- | --- |
| `Set-Disk -IsOffline $true` | **不可用**：`Removable media cannot be set to offline` |
| `mountvol F: /P` 卸载后立刻写 | **失败**：`设备未就绪` —— 卸载会让读卡器重新枚举，句柄拿不到设备 |
| **`FSCTL_LOCK_VOLUME` + `FSCTL_DISMOUNT_VOLUME`** | **成功**：设备保持就绪，只是独占写访问；卷句柄要一直持有到写完 |

最终 `write_sd.ps1` 走的第三条路，并带 6 次打开重试（应对枚举抖动）。
写入日志 `sd_write_log.txt` 会记录三处校验：1MB 处 `BM`、前 4096 字节逐字节、
第 6 张图起点。

> 换自己的图：把 640×480 24bit BMP 放进 `图片资源/`，或
> `python tools/make_sd_image.py -o my.img a.bmp b.bmp c.bmp`。
> 张数上限 255；`top_board.v` 的 `IMG_NUM` 要改成实际张数。

---

## 4. 可调参数（`top_board.v`）

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `SEC_BASE` | 2048 | 第 0 张图起始扇区 |
| `SEC_STRIDE` | 1801 | 每张图占用扇区数（同时是读取扇区数） |
| `IMG_NUM` | 6 | 循环张数 |
| `HOLD_FRM` | 90 | 每张停留帧数，30fps 下 3 秒 |

---

## 5. 上板现象与排查

**正常**：上电约 1 秒后出现第 1 张图，每 3 秒切下一张（切换时短暂黑屏约 0.4 秒），
OSD 菜单照旧可用。

| 现象 | 可能原因 | 排查 |
| --- | --- | --- |
| 一直黑屏 | SD 初始化失败 / 卡没插好 | 换卡；确认卡是 SPI 模式兼容（≤32GB 的 SDHC 一般都行） |
| 有图但花屏/颜色错乱 | BMP 格式不对（非 24bit/有压缩） | 用 `make_sd_image.py` 的校验输出确认 |
| 图像上下颠倒 | `biHeight > 0`（自底向上）本来就是正解 | `bmp_decode` 已支持两种，颠倒说明源图被工具垂直翻转过 |
| 反复显示同一张 | `IMG_NUM` 设成 1，或扇区偏移不对 | 检查 `SEC_BASE/SEC_STRIDE` 与镜像布局是否一致 |
| 切换后黑屏不恢复 | 读到卡末尾越界 | 确认镜像大小 ≥ `(SEC_BASE + IMG_NUM×SEC_STRIDE)×512` |
| 图像缺一块/撕裂 | SDRAM 带宽 | 已在 37.5MHz + FIFO 4096 下验证过，若出现先降 `IMG_NUM` 排除 |

---

## 6. 已知限制

1. **切换时黑屏约 0.4 秒**：单缓冲，加载新图时 `load_mode=1` 停读。
   要无缝切换需要 SDRAM 双缓冲（512K 字够放两帧 153600×2），但读侧要加缓冲区切换逻辑，后续再做。
2. **SPI 25MHz**：一张图 385ms。提到 50MHz 可减半，但部分卡不支持，先保守。
3. **不支持 FAT32**：见 §2。
4. **固定 640×480**：`frame_buffer` 的 `IMG_W/IMG_H` 与 `bmp_decode` 的居中位置绑定，
   换分辨率要同时改 `IMG_X0/IMG_Y0`。

---

## 7. 与前面几节的关系

- SDRAM 读带宽与 720p30 的来龙去脉见 `P7_BMP播放链路_设计.md` §5.7~§5.11；
- 上板 HDMI/OSD 部分见 `P6_OSD菜单_实现说明.md`。
