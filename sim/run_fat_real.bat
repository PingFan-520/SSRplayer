@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_real rmdir /s /q work_real
"%MS%\vlib.exe" work_real || goto ERR
"%MS%\vlog.exe" -work work_real +incdir+"%PRJ%\rtl\mem" ^
  "%PRJ%\rtl\sd\sd_arb.v" ^
  "%PRJ%\rtl\sd\sd_bmp_reader.v" ^
  "%PRJ%\sim\tb_fat_real.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_real.tb_fat_real
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
