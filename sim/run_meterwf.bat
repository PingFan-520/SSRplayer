@echo off
REM run_meterwf.bat -- audio_meter waterfall direction/fill unit test
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_mwf rmdir /s /q work_mwf
"%MS%\vlib.exe" work_mwf || goto ERR
"%MS%\vlog.exe" -work work_mwf "%PRJ%\rtl\audio\audio_meter.v" "%PRJ%\sim\tb_meter_wf.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_mwf.tb_meter_wf
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
