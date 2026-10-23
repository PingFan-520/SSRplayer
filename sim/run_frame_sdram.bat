@echo off
REM ===========================================================================
REM  run_frame_sdram.bat —— frame_buffer + 厂商 SDRAM 控制器 + IS42s32200 引脚模型
REM  用法：run_frame_sdram.bat            编译并跑完整仿真
REM        run_frame_sdram.bat nocompile  只跑（复用已有 work 库）
REM ===========================================================================
setlocal
set MS=E:\modelsim\win64
set PRJ=D:\Work\fpga\yuanshen
cd /d "%~dp0"

if /i "%1"=="nocompile" goto RUN

if exist work rmdir /s /q work
"%MS%\vlib.exe" work || goto ERR

"%MS%\vlog.exe" -work work +define+SIMULATION +incdir+"%PRJ%\rtl\mem" ^
  "%PRJ%\rtl\mem\global_def.v" ^
  "%PRJ%\rtl\mem\IS42s32200.v" ^
  "%PRJ%\rtl\mem\sdr_as_ram.enc.v" ^
  "%PRJ%\rtl\mem\sdr_init_ref.enc.v" ^
  "%PRJ%\rtl\mem\sdr_wrrd.enc.v" ^
  "%PRJ%\rtl\mem\sdram.v" ^
  "%PRJ%\rtl\mem\afifo.v" ^
  "%PRJ%\rtl\mem\frame_buffer.v" ^
  "%PRJ%\rtl\video\color_bar_hd.v" ^
  "%PRJ%\sim\tb_frame_sdram.v" || goto ERR

:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work.tb_frame_sdram
goto END

:ERR
echo [ERR] compile failed
:END
endlocal
