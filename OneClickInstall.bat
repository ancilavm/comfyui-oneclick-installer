@echo off
setlocal

cd /d "%~dp0"

echo =========================================
echo     ComfyUI One Click Installer
echo =========================================
echo.

:: Run PowerShell installer
powershell -NoProfile -ExecutionPolicy Bypass -File "installer\install.ps1"

echo.
echo =========================================
echo Done. Press any key to close.
echo =========================================
pause >nul
