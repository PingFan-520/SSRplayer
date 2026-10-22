@echo off
REM ===========================================================================
REM  run_sim.bat [tb_name]   default: tb_probe
REM     run_sim.bat            -> P1 频率探针自检
REM     run_sim.bat tb_video_hd-> 720p / 1024x768 时序自检
REM ===========================================================================
setlocal
set MS=E:\Modelsim_10.1c\win64
set TDSIM=E:\TD\sim_release\eg4
set TB=%1
if "%TB%"=="" set TB=tb_probe
cd /d "%~dp0"

if exist work rmdir /s /q work
"%MS%\vlib.exe" work

"%MS%\vlog.exe" -work work ^
  "%TDSIM%\eg_phy_glbl.v" ^
  "%TDSIM%\eg_phy_pll.v" ^
  "%TDSIM%\eg_logic_io.v" ^
  ..\rtl\common\seg7.v ^
  ..\rtl\probe\probe_top.v ^
  ..\rtl\video\color_bar_hd.v ^
  ..\rtl\video\rgb2axis.v ^
  ..\rtl\video\test_pattern_b.v ^
  ..\rtl\video\bmp_decode.v ^
  ..\rtl\ui\font_rom.v ^
  ..\rtl\ui\key_ctrl.v ^
  ..\rtl\ui\osd_menu.v ^
  ..\rtl\ui\alpha_blend.v ^
  ..\rtl\ui\transition.v ^
  ..\rtl\ui\param_apply.v ^
  ..\rtl\ui\cfg_latch.v ^
  ..\rtl\top_osd_demo.v ^
  tb_probe.v ^
  tb_bmp_decode.v ^
  tb_bmp_display.v ^
  tb_video_hd.v ^
  tb_osd_demo.v

if errorlevel 1 goto err

echo.
echo ---- running %TB% ----
"%MS%\vsim.exe" -c -novopt -do "run -all; quit -f" work.%TB% glbl
goto done

:err
echo.
echo [ERROR] compile failed
exit /b 1

:done
echo.
echo ---- done ----
