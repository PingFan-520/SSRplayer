@echo off
REM run_spec.bat -- spectrum (32-band Goertzel) unit test
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_spec rmdir /s /q work_spec
"%MS%\vlib.exe" work_spec || goto ERR
"%MS%\vlog.exe" -work work_spec "%PRJ%\rtl\audio\audio_meter.v" "%PRJ%\sim\tb_spectrum.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_spec.tb_spectrum
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
