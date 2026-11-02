@echo off
setlocal
cd /d "%~dp0"
set "PYTHONHOME=D:\Efinity\python311"
"%PYTHONHOME%\bin\python.exe" -B tools\lunaria_pc.py --folder "%~dp0output\lunaria"
if errorlevel 1 pause
