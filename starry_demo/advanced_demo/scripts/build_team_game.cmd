@echo off
setlocal
cd /d "%~dp0.."
set "TEAM_IDE=%~1"
if not defined TEAM_IDE set "TEAM_IDE=D:\Efinity\efinity-riscv-ide-2026.1"
if not exist "%TEAM_IDE%\toolchain\bin\riscv-none-elf-gcc.exe" if "%~1"=="" set "TEAM_IDE=C:\Efinity\efinity-riscv-ide-2026.1"
if not exist "%TEAM_IDE%\toolchain\bin\riscv-none-elf-gcc.exe" (
  echo RISC-V IDE not found. Pass the IDE folder as the first argument.
  exit /b 1
)
set "PYTHONHOME=%TEAM_IDE%\..\python311"
set "PYTHONIOENCODING=utf-8"
if not exist "%PYTHONHOME%\bin\python.exe" (
  echo Efinity Python not found beside the IDE. See docs\TEAM_SPRITES.md.
  exit /b 1
)
"%PYTHONHOME%\bin\python.exe" -B scripts\build_apb_software.py --program game --opt O2 --ide-root "%TEAM_IDE%" --define GAME_FLASH_ENABLE=0 --define GAME_TEAM_SPRITES=1 --define GAME_FULLSCREEN=1
exit /b %errorlevel%
