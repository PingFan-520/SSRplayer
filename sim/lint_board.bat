@echo off
REM ===========================================================================
REM  lint_board.bat —— 不跑仿真，只检查上板顶层的语法与端口
REM  HDMI 加密核用 sim\stub_hdmi_core.v 占位（不要加进 TD 工程）
REM ===========================================================================
setlocal
set MS=E:\Modelsim_10.1c\win64
set TDSIM=E:\TD\sim_release\eg4
cd /d "%~dp0"

if not exist lint mkdir lint
if exist lint\work rmdir /s /q lint\work
"%MS%\vlib.exe" lint\work

"%MS%\vlog.exe" -work lint\work ^
  "%TDSIM%\eg_phy_glbl.v" ^
  "%TDSIM%\eg_phy_pll.v" ^
  "%TDSIM%\eg_logic_io.v" ^
  ..\rtl\common\seg7.v ^
  ..\rtl\video\color_bar_hd.v ^
  ..\rtl\video\test_pattern_b.v ^
  ..\rtl\video\rgb2axis.v ^
  ..\rtl\ui\font_rom.v ^
  ..\rtl\ui\key_ctrl.v ^
  ..\rtl\ui\alpha_blend.v ^
  ..\rtl\ui\transition.v ^
  ..\rtl\ui\param_apply.v ^
  ..\rtl\ui\cfg_latch.v ^
  ..\rtl\ui\osd_menu.v ^
  ..\rtl\top_osd_demo.v ^
  ..\rtl\hdmi\lane_lvds_10_1.v ^
  ..\rtl\hdmi\hdmi_phy_warpper.v ^
  stub_hdmi_core.v ^
  ..\rtl\top_board.v

if errorlevel 1 goto err

echo.
echo ---- elaborating top_board ----
cd lint
"%MS%\vsim.exe" -c -novopt work.top_board glbl -do "run 1ms; echo LINT_OK; quit -f"
cd ..
goto done

:err
echo [ERROR] compile failed
exit /b 1

:done
echo ---- done ----
