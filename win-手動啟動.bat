@echo off
REM ClipSync launcher (Windows).
REM
REM This file is deliberately pure ASCII. cmd.exe parses .bat files using the
REM legacy ANSI code page, so UTF-8 Chinese text here gets mangled -- it breaks
REM not just the display but the command lines themselves. All Chinese UI lives
REM in start.ps1, which PowerShell reads as UTF-8 (it has a BOM).
chcp 65001 >nul
title ClipSync
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"

if errorlevel 1 pause
