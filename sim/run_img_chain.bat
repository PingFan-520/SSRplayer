@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_img rmdir /s /q work_img
"%MS%\vlib.exe" work_img || goto ERR
"%MS%\vlog.exe" -work work_img "%PRJ%\rtl\video\bmp_decode.v" "%PRJ%\rtl\video\bmp_scale.v" "%PRJ%\sim\tb_img_chain.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_img.tb_img_chain
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
