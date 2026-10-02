@echo off
REM Open the ClipSync web control panel. Pure ASCII wrapper -- all Chinese
REM UI lives in ui.ps1 (UTF-8 with BOM), because cmd.exe parses .bat files
REM with the legacy ANSI code page and would mangle the commands themselves.
chcp 65001 >nul
title ClipSync
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ui.ps1"
if errorlevel 1 pause
