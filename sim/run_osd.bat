@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_osd rmdir /s /q work_osd
"%MS%\vlib.exe" work_osd || goto ERR
"%MS%\vlog.exe" -work work_osd ^
  "%PRJ%\rtl\common\seg7.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\rtl\video\rgb2axis.v" ^
  "%PRJ%\rtl\video\test_pattern_b.v" ^
  "%PRJ%\rtl\video\bmp_decode.v" ^
  "%PRJ%\rtl\ui\font_rom.v" ^
  "%PRJ%\rtl\ui\key_ctrl.v" ^
  "%PRJ%\rtl\ui\osd_menu.v" ^
  "%PRJ%\rtl\ui\alpha_blend.v" ^
  "%PRJ%\rtl\ui\transition.v" ^
  "%PRJ%\rtl\ui\param_apply.v" ^
  "%PRJ%\rtl\ui\cfg_latch.v" ^
  "%PRJ%\rtl\audio\audio_meter.v" ^
  "%PRJ%\rtl\top_osd_demo.v" ^
  "%PRJ%\sim\tb_osd_demo.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_osd.tb_osd_demo
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
