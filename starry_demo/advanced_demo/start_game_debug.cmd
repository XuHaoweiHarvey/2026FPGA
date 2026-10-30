@echo off
setlocal
cd /d "%~dp0"
set "PYTHONHOME=D:\Efinity\python311"
if not exist "%PYTHONHOME%\bin\python.exe" (
  echo Efinity Python not found. Run tools\game_debug_window.py with Python 3 and Tkinter.
  pause
  exit /b 1
)
"%PYTHONHOME%\bin\python.exe" -B tools\game_debug_window.py %*
if errorlevel 1 pause
