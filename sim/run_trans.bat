@echo off
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_trans rmdir /s /q work_trans
"%MS%\vlib.exe" work_trans || goto ERR
"%MS%\vlog.exe" -work work_trans "%PRJ%\rtl\ui\transition.v" "%PRJ%\sim\tb_trans.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_trans.tb_trans
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
