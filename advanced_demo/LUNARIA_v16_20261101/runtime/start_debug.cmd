@echo off
setlocal
cd /d "%~dp0"
set "PYTHONHOME=D:\Efinity\python311"
"%PYTHONHOME%\bin\python.exe" -B tools\lunaria_debug_window.py --elf "%~dp0lunaria.elf" --assets "%~dp0assets.json"
if errorlevel 1 pause
