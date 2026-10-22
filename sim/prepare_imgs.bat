@echo off
REM ===========================================================================
REM  prepare_imgs.bat —— 把测试图片复制成 ASCII 文件名（ModelSim 读中文路径会挂）
REM  运行一次即可，图片本身不进 git
REM ===========================================================================
setlocal
cd /d "%~dp0"

copy /Y "..\图片资源\苹果_640x480_24bit_显示正常_工程适配版.bmp" img_test.bmp >nul
copy /Y "..\图片资源\苹果_640x480_24bit_显示正常_工程适配版.bmp" img_a.bmp   >nul
copy /Y "..\图片资源\西瓜_640x480_24bit_显示正常_工程适配版.bmp" img_b.bmp   >nul

echo prepared: img_test.bmp img_a.bmp img_b.bmp
