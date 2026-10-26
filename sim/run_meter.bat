@echo off
REM run_meter.bat -- top-level audio meter geometry check (tb_meter_full)
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_meter rmdir /s /q work_meter
"%MS%\vlib.exe" work_meter || goto ERR
"%MS%\vlog.exe" -work work_meter ^
  "%PRJ%\rtl\common\seg7.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\rtl\video\test_pattern_b.v" ^
  "%PRJ%\rtl\audio\audio_meter.v" ^
  "%PRJ%\rtl\ui\alpha_blend.v" ^
  "%PRJ%\rtl\ui\transition.v" ^
  "%PRJ%\rtl\ui\param_apply.v" ^
  "%PRJ%\rtl\ui\cfg_latch.v" ^
  "%PRJ%\rtl\ui\font_rom.v" ^
  "%PRJ%\rtl\ui\key_ctrl.v" ^
  "%PRJ%\rtl\ui\osd_menu.v" ^
  "%PRJ%\rtl\top_osd_demo.v" ^
  "%PRJ%\sim\tb_meter_full.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_meter.tb_meter_full
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
