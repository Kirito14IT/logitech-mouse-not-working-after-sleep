@echo off
chcp 65001 >nul
title Logitech G304 Mouse Recovery
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\LogitechMouseFix\Recover-Mouse.ps1" -Measure
echo.
echo Done. If the mouse still does not respond, run:
echo   E:\LogitechMouseFix\Fix-LogitechMouse.ps1
pause
