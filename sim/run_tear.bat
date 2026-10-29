@echo off
REM 切屏撕裂复现：后台整帧写 + 帧首换 bank
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_tear rmdir /s /q work_tear
"%MS%\vlib.exe" work_tear || goto ERR
"%MS%\vlog.exe" -work work_tear +define+SIMULATION +incdir+"%PRJ%\rtl\mem" ^
  "%PRJ%\rtl\mem\global_def.v" ^
  "%PRJ%\rtl\mem\IS42s32200.v" ^
  "%PRJ%\rtl\mem\sdr_as_ram.enc.v" ^
  "%PRJ%\rtl\mem\sdr_init_ref.enc.v" ^
  "%PRJ%\rtl\mem\sdr_wrrd.enc.v" ^
  "%PRJ%\rtl\mem\sdram.v" ^
  "%PRJ%\rtl\mem\afifo.v" ^
  "%PRJ%\rtl\mem\frame_buffer.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\sim\tb_tear.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_tear.tb_tear
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
