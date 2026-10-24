@echo off
REM ============================================================
REM  run_scale.bat -- bmp_scale unit / chain simulation
REM    run_scale.bat            : unit test (4 cases)
REM    run_scale.bat chain      : decode+scale chain, uses sim\scale_in.bmp
REM    run_scale.bat chain FILE : chain with a specific bmp
REM ============================================================
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"

if /i "%1"=="nocompile" goto RUN

if exist work_scale rmdir /s /q work_scale
"%MS%\vlib.exe" work_scale || goto ERR

"%MS%\vlog.exe" -work work_scale ^
  "%PRJ%\rtl\video\bmp_scale.v" ^
  "%PRJ%\rtl\video\bmp_decode.v" ^
  "%PRJ%\sim\tb_bmp_scale.v" ^
  "%PRJ%\sim\tb_bmp_scale_chain.v" || goto ERR

:RUN
if /i "%1"=="chain" goto CHAIN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_scale.tb_bmp_scale
goto END

:CHAIN
set BMP=%~2
if "%BMP%"=="" set BMP=%~dp0scale_in.bmp
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_scale.tb_bmp_scale_chain +FILE=%BMP%
goto END

:ERR
echo [ERR] compile failed
:END
endlocal
