@echo off
call "%~dp0python_runner.cmd" -B "%~dp0advanced_demo\scripts\build_lunaria_stress.py" --hardware prepare %*
if errorlevel 1 pause
