@echo off
REM ===========================================================================
REM  run_scale.bat ?? bmp_scale ????
REM  ???run_scale.bat            ????
REM        run_scale.bat nocompile  ??
REM ===========================================================================
setlocal
set MS=E:\modelsim\win64
set PRJ=D:\Work\fpga\yuanshen
cd /d "%~dp0"

if /i "%1"=="nocompile" goto RUN

if exist work_scale rmdir /s /q work_scale
"%MS%\vlib.exe" work_scale || goto ERR

"%MS%\vlog.exe" -work work_scale ^
  "%PRJ%\rtl\video\bmp_scale.v" ^
  "%PRJ%\sim\tb_bmp_scale.v" || goto ERR

:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_scale.tb_bmp_scale
goto END

:ERR
echo [ERR] compile failed
:END
endlocal
