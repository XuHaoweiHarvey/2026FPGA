@echo off
call "%~dp0python_runner.cmd" -B "%~dp0advanced_demo\tools\lunaria_debug_window.py" --pixelforge --elf "%~dp0advanced_demo\delivery\PixelForge\PixelForge.elf" --assets "%~dp0advanced_demo\delivery\PixelForge\assets.json" %*
if errorlevel 1 pause
