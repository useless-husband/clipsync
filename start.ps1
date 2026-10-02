# ClipSync 啟動器(Windows)—— 由 win-手動啟動.bat 呼叫,不用直接點這個檔。
#
# 這個檔案存成「UTF-8 with BOM」。PowerShell 5.1 在沒有 BOM 時會用系統的
# ANSI 編碼(繁中 Windows 是 cp950)讀檔,中文就會變亂碼 —— 有 BOM 才保險。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -Path $PSScriptRoot
try { $Host.UI.RawUI.WindowTitle = 'ClipSync' } catch {}

Clear-Host
Write-Host '  ClipSync — 區網剪貼簿同步'
Write-Host '  ────────────────────────────────────────'

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  ✗ 找不到 Dart SDK。' -ForegroundColor Red
    Write-Host ''
    Write-Host '  請開一個新的 PowerShell 視窗,執行:'
    Write-Host ''
    Write-Host '      winget install -e --id Google.DartSDK' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  裝完之後要「關掉這個視窗再重開」,PATH 才會生效。'
    Write-Host ''
    Write-Host '  winget 不能用的話,也可以到 https://dart.dev/get-dart 下載。'
    Write-Host ''
    Read-Host '  按 Enter 關閉'
    exit 1
}

$default = $env:COMPUTERNAME
Write-Host ''
Write-Host '  這台裝置要叫什麼名字?(其他裝置會看到這個名字)'
$name = Read-Host "  直接按 Enter 就用「$default」"
if ([string]::IsNullOrWhiteSpace($name)) { $name = $default }

Write-Host ''
Write-Host '  提醒:第一次跑會跳防火牆視窗,記得勾【私人網路】再按允許。'
Write-Host '  結束請打 /quit 按 Enter,或按 Ctrl+C。'
Write-Host ''

# --name 而不是位置參數:名字開頭是 - 時位置參數會被誤認成選項。
& dart run clipsync.dart --name $name
