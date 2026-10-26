@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_pmin rmdir /s /q work_pmin
"%MS%\vlib.exe" work_pmin || goto ERR
"%MS%\vlog.exe" -work work_pmin "%PRJ%\rtl\ui\param_apply.v" "%PRJ%\sim\tb_param_min.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_pmin.tb_param_min
goto END
:ERR
echo [ERR]
:END
endlocal
