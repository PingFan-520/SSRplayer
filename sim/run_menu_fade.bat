@echo off
REM ===========================================================================
REM  run_menu_fade.bat -- 菜单淡入淡出专项仿真（P25）
REM ===========================================================================
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_mf rmdir /s /q work_mf
"%MS%\vlib.exe" work_mf || goto ERR
"%MS%\vlog.exe" -work work_mf ^
  "%PRJ%\rtl\ui\osd_menu.v" ^
  "%PRJ%\rtl\ui\font_rom.v" ^
  "%PRJ%\sim\tb_menu_fade.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_mf.tb_menu_fade
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
