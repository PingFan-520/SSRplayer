@echo off
REM run_wav.bat -- wav_player (directory + raw PCM) unit test, 2 cases
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_wav rmdir /s /q work_wav
"%MS%\vlib.exe" work_wav || goto ERR
"%MS%\vlog.exe" -work work_wav "%PRJ%\rtl\mem\afifo.v" "%PRJ%\rtl\sd\sd_arb.v" "%PRJ%\rtl\audio\wav_player.v" "%PRJ%\sim\tb_wav.v" || goto ERR
:RUN
echo === case 1: good card (directory + raw PCM) ===
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_wav.tb_wav +FILE=%~dp0wav_sine.wav
echo.
echo === case 2: directory invalid (card from an old image) ===
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_wav.tb_wav +FILE=%~dp0wav_sine.wav +NODIR
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
