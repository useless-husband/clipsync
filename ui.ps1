# 打開 ClipSync 的網頁控制台(Windows)。由 win-控制台.bat 呼叫,不用直接點這個檔。
#
# 控制台是程式內建的網頁(http://127.0.0.1:53320,只有這台電腦看得到)。
# 沒在跑的話,先試著用「啟動」資料夾裡的捷徑把它拉起來。
#
# 這個檔案存成 UTF-8 with BOM —— PowerShell 5.1 沒有 BOM 時會用 cp950
# 讀檔,中文會變亂碼(理由同 autostart.ps1)。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-Location -Path $PSScriptRoot
try { $Host.UI.RawUI.WindowTitle = 'ClipSync 控制台' } catch {}

$url = 'http://127.0.0.1:53320'
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClipSync.vbs'

function Test-Up {
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', 53320).Wait(1000) -and $c.Connected
        $c.Close()
        return $ok
    } catch { return $false }
}

if (-not (Test-Up)) {
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
        foreach ($i in 1..6) {
            Start-Sleep -Seconds 1
            if (Test-Up) { break }
        }
    }
}

if (Test-Up) {
    Start-Process $url
    exit 0
}

Clear-Host
Write-Host ''
Write-Host '  ✗ ClipSync 沒有在執行,控制台打不開。' -ForegroundColor Red
Write-Host ''
Write-Host '    請先點兩下 win-手動啟動.bat(手動開一次),'
Write-Host '    或 win-設定開機自動啟動.bat(設定開機自動啟動)。'
Write-Host ''
Read-Host '  按 Enter 關閉'
exit 1
