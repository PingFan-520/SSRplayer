@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo [!] Need Administrator.
    echo     Right-click verify_sd.bat  and choose  "Run as administrator"
    echo.
    pause
    exit /b 1
)
echo.
echo === Verifying SD card against sd_image.img (read only) ===
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_sd.ps1"
echo.
pause
