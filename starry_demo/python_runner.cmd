@echo off
setlocal
cd /d "%~dp0"
if exist "%~dp0paths.local.cmd" call "%~dp0paths.local.cmd"
set "PYTHONHOME="
set "PYTHONPATH="
if defined FPGA_PYTHON goto explicit_python
where py >nul 2>&1
if errorlevel 1 goto try_python
py -3 -c "import tkinter" >nul 2>&1
if errorlevel 1 goto try_python
py -3 %*
exit /b %errorlevel%
:try_python
where python >nul 2>&1
if errorlevel 1 goto try_efinity
python -c "import tkinter" >nul 2>&1
if errorlevel 1 goto try_efinity
python %*
exit /b %errorlevel%
:try_efinity
if defined EFINITY_ROOT if exist "%EFINITY_ROOT%\python311\bin\python.exe" goto efinity_python
for %%D in (C D E F G H) do if exist "%%D:\Efinity\python311\bin\python.exe" set "EFINITY_ROOT=%%D:\Efinity"
if not defined EFINITY_ROOT goto missing_python
if not exist "%EFINITY_ROOT%\python311\bin\python.exe" goto missing_python
:efinity_python
set "PYTHONHOME=%EFINITY_ROOT%\python311"
"%PYTHONHOME%\bin\python.exe" %*
exit /b %errorlevel%
:explicit_python
if not exist "%FPGA_PYTHON%" goto missing_python
for %%P in ("%FPGA_PYTHON%") do if exist "%%~dpP..\Lib\encodings" set "PYTHONHOME=%%~dpP.."
"%FPGA_PYTHON%" %*
exit /b %errorlevel%
:missing_python
echo Python 3 with Tkinter was not found. Copy paths.local.cmd.example to paths.local.cmd and set FPGA_PYTHON.
exit /b 1
