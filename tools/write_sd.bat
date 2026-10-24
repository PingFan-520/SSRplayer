@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo [!] Need Administrator.
    echo     Right-click write_sd.bat  and choose  "Run as administrator"
    echo.
    pause
    exit /b 1
)
echo.
echo === Writing sd_image.img to PhysicalDrive2 ===
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0write_sd.ps1"
echo.
echo ============================================================
echo  Log file: D:\Work\fpga\yuanshen\sd_write_log.txt
echo ============================================================
pause
