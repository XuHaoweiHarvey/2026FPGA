@echo off
setlocal
call "D:\Visual Studio\Visual Studio 2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
cd /d "%~dp0.."
set "PYTHONHOME=D:\Efinity\python311"
"%PYTHONHOME%\bin\python.exe" -B scripts\run_showcase_checks.py
exit /b %errorlevel%
