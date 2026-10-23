@echo off
setlocal
rem Use the installed RISC-V IDE runtime for this Efinity session only.
rem Keep the Windows user/system PATH and the generated SoC/BSP unchanged.
set "EFINITY_ROOT=D:\Efinity"
set "JAVA_HOME=%EFINITY_ROOT%\efinity-riscv-ide-2026.1\Efinity-RISCV-IDE\jre"

if not exist "%JAVA_HOME%\bin\java.exe" (
    echo ERROR: Java was not found at "%JAVA_HOME%\bin\java.exe".
    echo Check the RISC-V IDE installation path in this launcher.
    if /i not "%~1"=="--check" pause
    exit /b 1
)
if not exist "%EFINITY_ROOT%\bin\efinity.exe" (
    echo ERROR: Efinity was not found at "%EFINITY_ROOT%\bin\efinity.exe".
    if /i not "%~1"=="--check" pause
    exit /b 1
)

rem Load the vendor Efinity environment before adding the bundled Java runtime.
call "%EFINITY_ROOT%\bin\setup.bat"
if errorlevel 1 (
    echo ERROR: Efinity setup.bat failed.
    if /i not "%~1"=="--check" pause
    exit /b 1
)

set "PATH=%JAVA_HOME%\bin;%PATH%"
"%JAVA_HOME%\bin\java.exe" -version
if errorlevel 1 (
    echo ERROR: The Java runtime could not start.
    if /i not "%~1"=="--check" pause
    exit /b 1
)
if /i "%~1"=="--check" (
    echo PASS: Java is available on the launcher PATH and Efinity exists.
    exit /b 0
)

rem Efinity is single-instance on this PC; refuse to forward into a stale process.
tasklist /FI "IMAGENAME eq efinity.exe" /NH | find /I "efinity.exe" >nul
if not errorlevel 1 (
    echo ERROR: An Efinity process is still running.
    echo Close every Efinity and IP Configuration window, then check Task Manager > Details for efinity.exe.
    echo Run this launcher again only after efinity.exe has exited.
    pause
    exit /b 1
)

echo Open the advanced_demo project, edit soc_control, enable UART0, then Generate.
start "" "%EFINITY_ROOT%\bin\efinity.exe"
if errorlevel 1 (
    echo ERROR: Efinity could not start.
    pause
    exit /b 1
)
endlocal
