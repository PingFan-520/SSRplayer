@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_nav rmdir /s /q work_nav
"%MS%\vlib.exe" work_nav || goto ERR
"%MS%\vlog.exe" -work work_nav "%PRJ%\rtl\ui\key_ctrl.v" "%PRJ%\sim\tb_nav_ctrl.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_nav.tb_nav_ctrl
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
