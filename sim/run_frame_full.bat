@echo off
REM 满屏帧缓存通路验证（960x540 -> 1280x720）
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_full rmdir /s /q work_full
"%MS%\vlib.exe" work_full || goto ERR
"%MS%\vlog.exe" -work work_full +define+SIMULATION +incdir+"%PRJ%\rtl\mem" ^
  "%PRJ%\rtl\mem\global_def.v" ^
  "%PRJ%\rtl\mem\IS42s32200.v" ^
  "%PRJ%\rtl\mem\sdr_as_ram.enc.v" ^
  "%PRJ%\rtl\mem\sdr_init_ref.enc.v" ^
  "%PRJ%\rtl\mem\sdr_wrrd.enc.v" ^
  "%PRJ%\rtl\mem\sdram.v" ^
  "%PRJ%\rtl\mem\afifo.v" ^
  "%PRJ%\rtl\mem\frame_buffer.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\sim\tb_frame_full.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_full.tb_frame_full
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
