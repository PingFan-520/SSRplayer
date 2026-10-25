@echo off
REM ===========================================================================
REM  lint_top.bat —— 用 ModelSim 对整板顶层做语法/端口检查（不跑仿真）
REM    HDMI 核用 sim/stub_hdmi_core.v 占位；SDRAM 用官方加密 IP + 引脚模型不参与
REM ===========================================================================
setlocal
set MS=E:\modelsim\win64
set TDSIM=E:\TD\sim_release\eg4
set PRJ=D:\Work\fpga\yuanshen
cd /d "%PRJ%\sim"

if exist lint_work rmdir /s /q lint_work
"%MS%\vlib.exe" lint_work || goto ERR

"%MS%\vlog.exe" -work lint_work +define+LINT_ONLY +incdir+"%PRJ%\rtl\mem" ^
  "%TDSIM%\eg_phy_pll.v" ^
  "%TDSIM%\eg_phy_glbl.v" ^
  "%TDSIM%\eg_logic_io.v" ^
  "%PRJ%\rtl\mem\global_def.v" ^
  "%PRJ%\rtl\mem\afifo.v" ^
  "%PRJ%\rtl\mem\frame_buffer.v" ^
  "%PRJ%\rtl\common\seg7.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\rtl\video\rgb2axis.v" ^
  "%PRJ%\rtl\video\test_pattern_b.v" ^
  "%PRJ%\rtl\video\pattern_src.v" ^
  "%PRJ%\rtl\video\bmp_decode.v" ^
  "%PRJ%\rtl\video\bmp_scale.v" ^
  "%PRJ%\rtl\sd\sd_init.v" ^
  "%PRJ%\rtl\sd\sd_read.v" ^
  "%PRJ%\rtl\sd\sd_ctrl_top.v" ^
  "%PRJ%\rtl\sd\sd_bmp_reader.v" ^
  "%PRJ%\rtl\sd\sd_arb.v" ^
  "%PRJ%\rtl\ui\font_rom.v" ^
  "%PRJ%\rtl\ui\key_ctrl.v" ^
  "%PRJ%\rtl\ui\osd_menu.v" ^
  "%PRJ%\rtl\ui\alpha_blend.v" ^
  "%PRJ%\rtl\ui\transition.v" ^
  "%PRJ%\rtl\ui\param_apply.v" ^
  "%PRJ%\rtl\ui\cfg_latch.v" ^
  "%PRJ%\rtl\top_osd_demo.v" ^
  "%PRJ%\sim\stub_hdmi_core.v" ^
  "%PRJ%\sim\stub_phy.v" ^
  "%PRJ%\sim\lint_stub_sdram.v" ^
  "%PRJ%\rtl\top_board.v" || goto ERR

echo [OK] lint passed
goto END
:ERR
echo [ERR] lint failed
:END
endlocal
