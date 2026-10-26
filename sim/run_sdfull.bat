@echo off
REM run_sdfull.bat -- bit-level SD slave + real sd_read + sd_arb + wav_player
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_sdfull rmdir /s /q work_sdfull
"%MS%\vlib.exe" work_sdfull || goto ERR
"%MS%\vlog.exe" -work work_sdfull "%PRJ%\rtl\mem\afifo.v" "%PRJ%\rtl\sd\sd_read.v" "%PRJ%\rtl\sd\sd_arb.v" "%PRJ%\rtl\audio\wav_player.v" "%PRJ%\sim\tb_sd_full.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_sdfull.tb_sd_full
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
