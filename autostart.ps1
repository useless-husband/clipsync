# ClipSync 開機自動啟動設定(Windows)。由 win-設定開機自動啟動.bat /
# win-取消開機自動啟動.bat 呼叫,不用直接點這個檔。
#
# 做法:編譯成 clipsync.exe,然後在「啟動」資料夾放一個 .vbs,
# 由它以隱藏視窗的方式啟動。用啟動資料夾而不是工作排程器,是因為
# 前者不需要系統管理員權限。
#
# 這個檔案存成 UTF-8 with BOM —— PowerShell 5.1 沒有 BOM 時會用 cp950
# 讀檔,中文會變亂碼。

param([ValidateSet('install', 'remove')][string]$Action = 'install')

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -Path $PSScriptRoot
try { $Host.UI.RawUI.WindowTitle = 'ClipSync 自動啟動' } catch {}

$startup  = [Environment]::GetFolderPath('Startup')
$vbs      = Join-Path $startup 'ClipSync.vbs'
$runner   = Join-Path $PSScriptRoot 'run-hidden.cmd'
$nameFile = Join-Path $PSScriptRoot 'device-name.txt'
$exe      = Join-Path $PSScriptRoot 'clipsync.exe'
$trayExe  = Join-Path $PSScriptRoot 'ClipSyncTray.exe'
$traySrc  = Join-Path $PSScriptRoot 'windows-tray\ClipSyncTray.cs'
$trayIco  = Join-Path $PSScriptRoot 'windows-tray\ClipSync.ico'
$log      = Join-Path $env:LOCALAPPDATA 'ClipSync.log'

# 只殺「我們這份 clipsync.exe」:比對 Path。別的使用者的程序讀不到 Path
# (擲例外→算 $null),自然被濾掉,不會誤殺別人的東西。
function Stop-OurClipsync {
    Get-Process clipsync -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -eq $exe } catch { $false } } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process ClipSyncTray -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -eq $trayExe } catch { $false } } |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# 每台 Windows 都內建 .NET Framework 的 C# 編譯器 —— 用它把通知區小圖示
# (windows-tray\ClipSyncTray.cs)編成真正的 .exe,一毛錢的安裝都不用。
function Find-Csc {
    foreach ($p in @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )) { if (Test-Path $p) { return $p } }
    return $null
}

Clear-Host
Write-Host '  ClipSync — 開機自動啟動'
Write-Host '  ────────────────────────────────────────'

if ($Action -eq 'remove') {
    Write-Host ''
    if (Test-Path $vbs) { Remove-Item $vbs -Force; Write-Host '  ✓ 已移除自動啟動設定' }
    else { Write-Host '  (本來就沒有設定自動啟動)' }
    Stop-OurClipsync
    Write-Host '  ✓ 已停止背景執行的 ClipSync'
    Write-Host ''
    Write-Host '  以後要用的話,點兩下 win-手動啟動.bat 手動開。'
    Write-Host ''
    Read-Host '  按 Enter 關閉'
    exit 0
}

if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
    Write-Host ''
    Write-Host '  ✗ 找不到 Dart SDK,無法編譯執行檔。' -ForegroundColor Red
    Write-Host '    請先執行:winget install -e --id Google.DartSDK'
    Write-Host '    裝完要關掉視窗再重開。'
    Write-Host ''
    Read-Host '  按 Enter 關閉'
    exit 1
}

$default = $env:COMPUTERNAME
Write-Host ''
Write-Host '  這台裝置要叫什麼名字?(另一台電腦會看到這個名字)'
$name = Read-Host "  直接按 Enter 就用「$default」"
if ([string]::IsNullOrWhiteSpace($name)) { $name = $default }

Write-Host ''
Write-Host '  正在編譯執行檔…(第一次要等一下)'
& dart compile exe clipsync.dart -o clipsync.exe
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    Write-Host '  ✗ 編譯失敗' -ForegroundColor Red
    Read-Host '  按 Enter 關閉'
    exit 1
}

# ── 通知區小圖示(右下角那種原生 UI)──
$trayOk = $false
$csc = Find-Csc
if ((Test-Path $traySrc) -and $csc) {
    Write-Host '  正在編譯通知區小圖示…'
    & $csc /nologo /target:winexe "/out:$trayExe" "/win32icon:$trayIco" `
        /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
        /r:System.Runtime.Serialization.dll "$traySrc"
    if ($LASTEXITCODE -eq 0 -and (Test-Path $trayExe)) { $trayOk = $true }
    else { Write-Host '  ⚠ 小圖示編譯失敗(不影響同步;網頁控制台 win-控制台.bat 仍可用)' -ForegroundColor Yellow }
} elseif (Test-Path $traySrc) {
    Write-Host '  ⚠ 找不到內建的 C# 編譯器,略過通知區小圖示' -ForegroundColor Yellow
}

# 裝置名稱寫進獨立的 UTF-8 檔,程式用 --name-file 讀。
# 絕對不要把名字內嵌進 .cmd:名字裡的 & | > 對 cmd 是中繼字元(等於讓
# 裝置名稱變成可以夾帶指令),而且 .cmd 的 OEM 編碼吃不下 emoji。
Set-Content -Path $nameFile -Value $name -Encoding UTF8

# 中介的 .cmd 負責切目錄與接記錄檔;.vbs 只負責「隱藏視窗地叫它」。
# 拆成兩個檔是為了避開 VBScript 裡巢狀引號的地獄。
@"
@echo off
cd /d "$PSScriptRoot"
"$exe" --name-file "device-name.txt" >> "$log" 2>&1
"@ | Set-Content -Path $runner -Encoding OEM

# .vbs 一定要存成 Unicode(UTF-16 LE):之前用 ASCII,路徑裡的中文全部
# 變成 '?',WScript 找不到檔案,每次登入都跳錯誤視窗、程式永遠起不來。
# WSH 原生支援 UTF-16(帶 BOM),中文路徑安然無恙。
# 登入時帶起兩個東西:背景服務(隱藏)+ 通知區小圖示(有編出來的話)。
$vbsLines = "Set s = CreateObject(""WScript.Shell"")`r`ns.Run """"""$runner"""""", 0, False"
if ($trayOk) { $vbsLines += "`r`ns.Run """"""$trayExe"""""", 0, False" }
$vbsLines | Set-Content -Path $vbs -Encoding Unicode

Stop-OurClipsync
Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
Start-Sleep -Seconds 3

Write-Host ''
$running = Get-Process clipsync -ErrorAction SilentlyContinue |
    Where-Object { try { $_.Path -eq $exe } catch { $false } }
if ($running) {
    Write-Host '  ✓ 設定完成,ClipSync 已在背景執行,以後開機會自動啟動。'
} else {
    Write-Host '  ⚠ 已安裝,但目前沒偵測到執行中的程序。看一下記錄檔:' -ForegroundColor Yellow
    Write-Host "      $log"
}

Write-Host ''
Write-Host "  裝置名稱   $name"
Write-Host "  記錄檔     $log"
Write-Host '  ────────────────────────────────────────'
Write-Host ''
Write-Host '  常用操作:'
Write-Host ''
if ($trayOk) {
    Write-Host '    🖥 圖形介面      右下角通知區的剪貼簿圖示(點右鍵:狀態、暫停、送文字)'
    Write-Host '                    (被 Windows 收進 ^ 摺疊區的話,把它拖出來釘住)'
}
Write-Host '    完整控制台      點兩下 win-控制台.bat(看活動記錄等細節)'
Write-Host "    看即時記錄      Get-Content -Wait `"$log`""
Write-Host '    取消自動啟動    點兩下 win-取消開機自動啟動.bat'
Write-Host ''
Write-Host '  ⚠ 複製密碼之前記得先暫停(圖示右鍵 → 暫停同步)——'
Write-Host '    不然會直接同步到另一台電腦。'
Write-Host ''
Read-Host '  按 Enter 關閉'
