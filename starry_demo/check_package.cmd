@echo off
call "%~dp0python_runner.cmd" -B "%~dp0advanced_demo\scripts\team_project.py" verify %*
if errorlevel 1 pause
