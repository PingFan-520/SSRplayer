@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_ms rmdir /s /q work_ms
"%MS%\vlib.exe" work_ms || goto ERR
"%MS%\vlog.exe" -work work_ms "%PRJ%\rtl\audio\audio_meter.v" "%PRJ%\sim\tb_meter_style.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_ms.tb_meter_style
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
