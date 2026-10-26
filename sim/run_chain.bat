@echo off
REM run_chain.bat -- sd_arb + sd_bmp_reader integration (fake SD, real timing)
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_chain rmdir /s /q work_chain
"%MS%\vlib.exe" work_chain || goto ERR
"%MS%\vlog.exe" -work work_chain "%PRJ%\rtl\sd\sd_arb.v" "%PRJ%\rtl\sd\sd_bmp_reader.v" "%PRJ%\sim\tb_sd_chain.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_chain.tb_sd_chain
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
