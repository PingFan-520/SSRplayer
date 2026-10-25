@echo off
REM run_audio.bat -- tone_gen + audio_meter 单元测试
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_audio rmdir /s /q work_audio
"%MS%\vlib.exe" work_audio || goto ERR
"%MS%\vlog.exe" -work work_audio "%PRJ%\rtl\audio\tone_gen.v" "%PRJ%\rtl\audio\audio_meter.v" "%PRJ%\sim\tb_audio.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_audio.tb_audio
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
