@echo off
setlocal
cd /d "%~dp0"

echo =========================================
echo     ComfyUI One Click Installer
echo =========================================
echo.
echo NOTE:
echo This installer will download ComfyUI, Python packages, and custom nodes.
echo Some antivirus tools may block PowerShell automation.
echo.
pause

powershell -NoProfile -ExecutionPolicy RemoteSigned -File "installer\install.ps1"

echo.
echo =========================================
echo Done. Press any key to close.
echo =========================================
pause >nul
