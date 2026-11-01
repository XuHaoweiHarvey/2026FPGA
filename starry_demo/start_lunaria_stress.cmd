@echo off
call "%~dp0python_runner.cmd" -B "%~dp0advanced_demo\tools\lunaria_debug_window.py" --stress --elf "%~dp0advanced_demo\delivery\lunaria_stress\lunaria.elf" --assets "%~dp0advanced_demo\delivery\lunaria_stress\assets.json" %*
if errorlevel 1 pause
