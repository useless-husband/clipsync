@echo off
chcp 65001 >nul
title ClipSync autostart
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autostart.ps1" -Action remove
if errorlevel 1 pause
