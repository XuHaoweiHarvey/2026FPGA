@echo off
setlocal
call "D:\Visual Studio\Visual Studio 2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
cd /d "%~dp0.."
set "PYTHONHOME="
"C:\Users\Xuhaowei\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe" -B scripts\build_lunaria_pc.py
exit /b %errorlevel%
