@echo off
REM Pure ASCII wrapper. All Chinese UI lives in autostart.ps1 (UTF-8 with BOM),
REM because cmd.exe parses .bat files with the legacy ANSI code page.
chcp 65001 >nul
title ClipSync autostart
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0autostart.ps1" -Action install
if errorlevel 1 pause
