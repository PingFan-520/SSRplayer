# ============================================================================
#  probe.sdc —— P1 频率探针时序约束
#  目标：让 TD 对 375MHz 串行时钟做真实时序分析，别被当成 false path 放过
# ============================================================================

# 板载 50MHz 晶振
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# 自动推导 PLL 输出时钟（TD 读取 EG_PHY_PLL 的分频参数）
derive_clocks

# ----------------------------------------------------------------------------
# 可选：给 PLL 输出命名，方便在 Timing Analyzer 里认。
# 实例路径按综合后的实际名字调整（本工程实例名为 u_pll）：
#   rename_clock -name clk_pix -source [get_ports {clk}] -master_clock {clk} \
#                [get_pins {u_pll/pll_inst.clkc[0]}]
#   rename_clock -name clk_ser -source [get_ports {clk}] -master_clock {clk} \
#                [get_pins {u_pll/pll_inst.clkc[1]}]
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 注意：本探针工程故意 **不** 把 75MHz 与 375MHz 设成 false path。
#       375MHz 的 slack 正是我们要看的指标，屏蔽掉就失去意义了。
#
#       像素域与串行域之间只有 pix_tog 一个 2FF 同步器，
#       若报告出现这两个域之间的建立/保持违例，先确认违例路径
#       全部经过 tog_sync 三级寄存器，再决定是否加：
#
#   set_false_path -from [get_clocks {clk_pix}] -to [get_clocks {clk_ser}]
#   set_false_path -from [get_clocks {clk_ser}] -to [get_clocks {clk_pix}]
# ----------------------------------------------------------------------------
