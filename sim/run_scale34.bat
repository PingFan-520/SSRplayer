@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_s34 rmdir /s /q work_s34
"%MS%\vlib.exe" work_s34 || goto ERR
"%MS%\vlog.exe" -work work_s34 "%PRJ%\rtl\video\bmp_scale.v" "%PRJ%\sim\tb_scale34.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_s34.tb_scale34
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
