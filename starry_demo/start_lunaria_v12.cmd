@echo off
call "%~dp0python_runner.cmd" -B "%~dp0advanced_demo\tools\lunaria_debug_window.py" --elf "%~dp0advanced_demo\delivery\lunaria_v12\lunaria.elf" --assets "%~dp0advanced_demo\delivery\lunaria_v12\assets.json" %*
if errorlevel 1 pause
