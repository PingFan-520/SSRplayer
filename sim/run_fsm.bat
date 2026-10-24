@echo off
REM run_fsm.bat -- carousel FSM unit test (code extracted from top_board.v)
setlocal
set MS=E://modelsim//win64
set PRJ=D://Work//fpga//yuanshen
cd /d "%~dp0"
if /i "%1"=="nocompile" goto RUN
if exist work_fsm rmdir /s /q work_fsm
"%MS%\vlib.exe" work_fsm || goto ERR
"%MS%\vlog.exe" -work work_fsm "%PRJ%\sim\tb_fsm.v" || goto ERR
:RUN
"%MS%\vsim.exe" -c -do "run -all; quit -f" work_fsm.tb_fsm
goto END
:ERR
echo [ERR] compile failed
:END
endlocal
