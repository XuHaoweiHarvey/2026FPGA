@echo off
setlocal
cd /d "%~dp0.."
set "STRESS_OPT_IDE=%~1"
if not defined STRESS_OPT_IDE set "STRESS_OPT_IDE=D:\Efinity\efinity-riscv-ide-2026.1"
set "PYTHONHOME=%STRESS_OPT_IDE%\..\python311"
if not exist "%PYTHONHOME%\bin\python.exe" exit /b 1
"%PYTHONHOME%\bin\python.exe" -B scripts\build_apb_software.py --program game --opt O2 --ide-root "%STRESS_OPT_IDE%" --output software\interactive_demo\build\game-window640-stress-opt --define GAME_FLASH_ENABLE=0 --define GAME_TEAM_SPRITES=1 --define GAME_TEAM_BACKGROUND=1 --define GAME_FULLSCREEN=0 --define GAME_REQUIRE_QUEUE=1 --define GAME_PATH_DIAGNOSTICS=1 --define GAME_SUBMIT_TIMING=0 --define GAME_DISPLAY_WINDOW=1 --define GAME_STRESS_TUNING=1 --define GAME_ENEMY_BULLET_CAPACITY=512 --define GAME_WINDOW_HUD_CACHE=1
exit /b %errorlevel%
