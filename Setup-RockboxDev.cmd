@echo off
rem Double-click this file to run the Rockbox development setup.
rem The first time (to install WSL), right-click it and choose "Run as administrator".
rem It starts Setup-RockboxDev.ps1 without changing your PowerShell execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-RockboxDev.ps1" %*
rem Exit code 2 = "run again as administrator"; the script already waited for the user.
if %errorlevel% equ 2 exit /b 2
echo.
pause
