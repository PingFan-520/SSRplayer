@echo off
setlocal
set MS=E:/modelsim/win64
set PRJ=D:/Work/fpga/yuanshen
cd /d "%~dp0"
if exist work_fat rmdir /s /q work_fat
"%MS%\vlib.exe" work_fat || goto ERR
"%MS%\vlog.exe" -work work_fat +incdir+"%PRJ%\rtl\mem" ^
  "%PRJ%\rtl\mem\afifo.v" ^
  "%PRJ%\rtl\sd\sd_arb.v" ^
  "%PRJ%\rtl\sd\sd_bmp_reader.v" ^
  "%PRJ%\rtl\audio\wav_player.v" ^
  "%PRJ%\sim\tb_fat_chain.v" || goto ERR
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_fat.tb_fat_chain %*
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
