# ClipSync — 區網剪貼簿同步(Step 3:文字 / 圖片 / 檔案)

> *English:* ClipSync syncs your clipboard (text, images, files) between computers on the same LAN. Pure Dart core with zero dependencies, UDP discovery + HTTP transfer, a native macOS menu-bar app (Swift) and a Windows tray app (C#). Documentation below is in Traditional Chinese.

在 A 電腦複製文字、截圖、或在檔案總管複製檔案,B 電腦直接 Ctrl/Cmd+V 就貼得出來。純 Dart,不需要 Flutter,零外部套件。

## 演進

| | Step 1 | Step 2 | **Step 3(現在)** |
|---|---|---|---|
| 觸發 | 手動打字按 Enter | 自動偵測剪貼簿變化 | ← 同左 |
| 收到後 | 印在終端機 | 寫入剪貼簿 + 回音防護 | ← 同左 |
| 傳輸 | UDP(64KB 上限) | HTTP POST(JSON body) | **HTTP POST(原始二進位 body)** |
| 支援內容 | 文字 | 文字 | **文字 + 圖片 + 檔案** |
| 裝置身分 | 比對名字 | 持久化 deviceId | + 協定版本檢查 |

Step 1 的原始檔留在 `step1_discovery.dart` 當對照。

---

## 安裝 Dart(每台電腦只要做一次)

```bash
# macOS
brew install dart-sdk

# Windows(PowerShell)
winget install -e --id Google.DartSDK
```

Windows 裝完**要關掉視窗再重開**,PATH 才會生效。winget 不能用就到 <https://dart.dev/get-dart> 下載。確認:`dart --version`。

> 套件 ID 是 `Google.DartSDK`,不是 `dart.dartsdk`(後者不存在,winget 會回「未找到符合輸入條件的套件」)。

---

## 跑起來

**最簡單:點兩下。** Mac 點 `mac-手動啟動.command`,Windows 點 `win-手動啟動.bat`,它會問你要取什麼裝置名字,按 Enter 就開始跑。

或用終端機,兩台同一個 Wi-Fi 的電腦各開一個:

```bash
dart run clipsync.dart Alice     # 電腦 A
dart run clipsync.dart Bob       # 電腦 B
```

看到 `✓ 發現裝置` 就成功了。之後複製任何東西都會自動同步:

```
21:08:10  📤 複製到文字:今天中午吃什麼  (21 B)
21:08:14  🖼  Alice → 已寫入圖片:1.1 MB,可以直接貼上
21:08:22  📁 Alice → 已收下 2 個檔案,存在 ~/Downloads/ClipSync,並已放進剪貼簿
```

> **兩台的版本一定要一樣。** 舊版收到新格式只會回 HTTP 500。程式會偵測到並提醒你,但不會自動修 —— 換版本時記得整個資料夾重新複製過去。

### 開機自動啟動(背景執行)

不想每次都手動開的話:

| | 安裝 | 取消 |
|---|---|---|
| macOS | 點兩下 `mac-設定開機自動啟動.command` | `mac-取消開機自動啟動.command` |
| Windows | 點兩下 `win-設定開機自動啟動.bat` | `win-取消開機自動啟動.bat` |

安裝時會先用 `dart compile exe` 編成原生執行檔,再登記成背景服務(macOS 是 launchd 的 LaunchAgent,Windows 是「啟動」資料夾裡的隱藏啟動器)。都不需要管理員權限。

編成執行檔有三個好處:背景啟動時不會載入 shell 設定、`dart` 常常不在 PATH 裡;`dart run` 每次啟動要重新編譯、慢好幾秒;編完之後就算移除 Dart SDK 也能跑。

記錄檔:

```bash
tail -f ~/Library/Logs/ClipSync.log                    # macOS
Get-Content -Wait "$env:LOCALAPPDATA\ClipSync.log"     # Windows
```

**背景執行時沒有終端機可以打 `/pause`**,所以暫停改用一個旗標檔控制:

```bash
touch ~/.clipsync/paused   # 暫停(兩種模式、所有實例都會一起暫停)
rm ~/.clipsync/paused      # 恢復
```

> ⚠ 自動啟動 = 你複製的每一段文字都會即時送到另一台電腦,而且沒有視窗提醒你。**複製密碼前記得先暫停。**

### 🖥 圖形介面

核心邏輯全部在純 Dart 的背景服務裡;UI 是薄薄的一層皮,透過本機 API
(`http://127.0.0.1:53320`)跟它講話。皮有兩種:

**macOS:選單列圖示(原生,像 Mos 那樣)。** 螢幕右上角的剪貼簿圖示,
點開是選單:同步狀態、連上的電腦、一鍵暫停/恢復、送一段文字、打開收件匣。
圖示會跟著狀態變(⏸ = 已暫停、⟳! = 服務沒在跑)。原始碼在
`macos-menubar/main.swift` —— 一個檔案的 AppKit App,`swiftc` 直接編,
不需要 Xcode 專案。安裝腳本會把它放進「應用程式」並設定登入自動開。

**Windows:通知區圖示(右下角,原生 .exe)。** 功能與 macOS 版一對一:
右鍵選單看狀態/暫停/送文字/開收件匣,圖示右下角的小點表示狀態
(無 = 同步中、橘 = 已暫停、紅 = 服務沒在跑),點兩下圖示開完整控制台。
原始碼在 `windows-tray/ClipSyncTray.cs` —— 一個檔案的 WinForms App,
**每台 Windows 都內建 C# 編譯器**(`csc.exe`),安裝腳本自動把它編成
`ClipSyncTray.exe`,一樣零安裝。語法停在 C# 5,因為內建編譯器只認到這版。

**網頁控制台(完整版,兩平台通用)。** 上面兩個圖示是精簡版;完整功能
(活動記錄、詳細狀態)在網頁控制台:

| | 打開方式 |
|---|---|
| macOS | 選單列圖示 →「完整控制台」,或點兩下 `mac-控制台.command` |
| Windows | 通知區圖示點兩下(或右鍵 →「完整控制台」),或點兩下 `win-控制台.bat` |
| 通用 | 程式跑著時,瀏覽器開 <http://127.0.0.1:53320> |

兩台電腦的網頁畫面**完全相同**(同一份 HTML)。頁面內嵌在程式裡,零框架、
零外部資源,斷網也能開。

安全設計(報告可以寫):控制台 API **只綁 127.0.0.1**,區網其他電腦連不進來;
比對 `Host` 標頭擋 DNS rebinding;所有會改狀態的 POST 都要求自訂標頭
`x-clipsync-ui`,跨站網頁發不出這種請求(CSRF 防護)。細節在 `src/webui.dart` 檔頭。
選單列 App 也是走同一組 API —— 同一套防護、同一個資料來源,UI 之間永遠一致。

### 只有一台電腦?

開兩個終端機、**用不同名字**跑(內容埠會自動避開衝突):

```bash
dart run clipsync.dart Alice
dart run clipsync.dart Bob
```

### 指令

| 指令 | 作用 |
|---|---|
| `/peers` `/p` | 列出已發現的裝置(含協定版本) |
| `/ui` | 用瀏覽器打開網頁控制台 |
| `/push` | 把目前剪貼簿內容再推一次 |
| `/send 文字` | 直接送一段文字,不碰本機剪貼簿 |
| `/inbox` | 顯示並開啟收檔資料夾 |
| `/pause` / `/resume` | 暫停 / 恢復(**複製密碼前記得 /pause**) |
| `/status` `/s` | 狀態與統計 |
| `/quit` `/q` | 離開 |

啟動選項:`--no-files`、`--inbox <路徑>`、`--max-mb <n>`、`--poll <毫秒>`、`--content-port <n>`、`--paused`、`--open`、`--help`。

---

## 檔案同步

收到的檔案存在 `~/Downloads/ClipSync/`(用 `--inbox` 可以改),同時放進剪貼簿,所以可以直接貼到別的資料夾。

同名不會覆蓋,會變成 `報告 (2).pdf`。

**上限**(可用 `--max-mb` 調整總量):單檔 200MB、單次傳輸 512MB。超過就拒收並在兩邊都記錄原因。不想收檔案就加 `--no-files`。

---

## 架構

```
        ┌────────────── 電腦 A ──────────────┐        ┌──── 電腦 B ────┐
剪貼簿 ──┤ watcher.dart                       │        │                │
 (輪詢) │  每 700ms probe() 一次              │        │                │
        │  ↑ 只讀「摘要」,不讀圖片位元組       │        │                │
        │  變了 → onLocalChange               │        │                │
        │        │                            │        │                │
        │        ▼                            │ HTTP   │                │
        │ transport.dart ── POST /clip ───────┼───────▶│ ContentServer  │
        │   meta 放標頭、body 是原始位元組     │  TCP   │      │         │
        │   檔案:一個檔一個 POST,串流不進記憶體│        │      ▼         │
        │                                    │        │ applyRemote()  │
        │ discovery.dart ── hello 心跳 ───────┼───────▶│  → 寫入剪貼簿   │
        │   每 2 秒廣播,UDP 53317             │  UDP   │  → 檔案落地     │
        └────────────────────────────────────┘        └────────────────┘
```

**為什麼探索走 UDP、內容走 HTTP?** 心跳是「小、頻繁、丟了也沒差」→ UDP 廣播最適合。內容是「可能很大、一定要完整送到」→ 需要 TCP 的分段重傳與順序保證,HTTP 還免費附送「對方收到沒」的狀態碼。AirDrop、LocalSend 都是這個分法。

**為什麼 body 是二進位而不是 JSON?** 圖片塞進 JSON 要先 base64,體積膨脹 33%,而且整包都得先讀進記憶體才能解析。現在中繼資料放在 `x-clipsync-meta` 標頭(base64 過的 JSON),body 完全留給原始位元組,大檔可以邊收邊寫進磁碟。

### 檔案

| 檔案 | 負責 |
|---|---|
| `mac-手動啟動.command` | 點兩下就能跑的啟動器(Mac) |
| `win-手動啟動.bat` + `start.ps1` | 同上(Windows,見〈踩過的坑〉第 6 點) |
| `mac-設定開機自動啟動.command` / `mac-取消開機自動啟動.command` | 設定/取消開機自動啟動(Mac) |
| `win-設定開機自動啟動.bat` / `win-取消開機自動啟動.bat` + `autostart.ps1` | 同上(Windows) |
| `mac-控制台.command` / `win-控制台.bat` + `ui.ps1` | 打開網頁控制台 |
| `macos-menubar/` | macOS 選單列 App(Swift 原生外皮) |
| `windows-tray/` | Windows 通知區圖示(C# 原生外皮,安裝時自動編譯) |
| `clipsync.dart` | 進入點:組裝各模組、指令列、核心迴圈 |
| `src/watcher.dart` | **最重要**:偵測變化 + 三層回音防護 |
| `src/clipboard.dart` | 跨平台剪貼簿讀寫,三種格式 × 三個平台 |
| `src/clip_content.dart` | 內容模型與「輕量快照」 |
| `src/transport.dart` | HTTP 伺服器與送件端、檔案串流與組裝 |
| `src/discovery.dart` | UDP 心跳廣播與接收 |
| `src/peer.dart` | 裝置清單(之後在 Flutter 會變成 ChangeNotifier) |
| `src/message.dart` | 中繼資料格式與寬鬆解析 |
| `src/config.dart` | 所有常數(之後會變成設定頁的選項) |
| `src/util.dart` | deviceId、雜湊、預覽字串、debug 開關 |

平台差異全部關在 `clipboard.dart` 的 `SystemClipboard` 抽象類別後面。搬進 Flutter 時只要多寫一個 `FlutterClipboard implements SystemClipboard`,上層邏輯一行都不用改。

---

## 回音迴圈:這個專題最核心的問題

A 複製 → 寫進 B 的剪貼簿 → **B 偵測到「剪貼簿變了」** → 傳回 A → A 寫入 → A 也偵測到 → … 兩台機器互丟到天荒地老。

`watcher.dart` 用三層擋:

1. **寫入期間完全停止偵測**,寫完之後**重新 probe 一次**記下「系統現在實際上長什麼樣」。
   為什麼要重新問系統而不是自己算?因為檔案同步時,對方傳來的路徑跟我方落地後的路徑**根本不一樣**(存到我的 Downloads 底下,還可能因為同名變成「報告 (2).pdf」)。自己猜一定猜錯。
2. **靜音期**:寫入後 500ms 內偵測到的變化只更新記錄、不往外送。對付會在你寫入後又改寫一次的剪貼簿管理員(Maccy、Ditto)。
3. **送出端再比一次 signature**:同一份內容不重複廣播 → 迴圈必定收斂。

實測:同步文字、1.1MB 圖片、多檔案之後靜置 12 秒,兩邊日誌各新增 **0 行**,收件匣檔案數不變。

---

## 踩過的坑(可以直接寫進報告)

**1. 檔案同步「不是冪等的」,會炸出無限迴圈**
文字和圖片是冪等的:A 複製 X、B 寫入 X,兩邊 signature 一樣,迴圈自然停。
**但檔案不是。** B 把檔案存到自己的 `Downloads/ClipSync`,路徑跟 A 給的完全不同,於是 B 的剪貼簿看起來就像「使用者剛複製了新檔案」→ 又傳回 A → A 存成 `f (2).txt` → 再傳回去…… 檔案會等比級數增生。
解法:自動偵測到的檔案如果**全都在自己的收件匣裡**,就不再送出去(要轉送請用 `/push` 明確指定)。

**2. 遠端給的檔名一定要消毒**
`name` 欄位是對方送來的。不處理的話,對方送一個叫 `../../.ssh/authorized_keys` 的檔案就能寫到任意位置 —— 這是經典的 path traversal。`transport.dart` 的 `_safeName()` 會砍掉路徑分隔符、控制字元與開頭的點。

**3. 版本不合要講人話**
區網上只要還有一台跑舊版,每次複製都會噴「送不到 xxx:HTTP 500」,使用者只會覺得程式壞了。現在心跳裡帶協定版本,版本不合就跳過並**只提醒一次**:「跑的是舊版,請重新複製資料夾過去」。

**4. deviceId 撞號 → 兩個實例互相看不見**
一開始把 deviceId 存在 `~/.clipsync/device_id`,同一台電腦開兩個實例會讀到**同一個 ID**,雙方把對方的心跳當成「自己的回音」丟掉 —— 封包一直在飛,卻永遠顯示「還沒發現任何裝置」。現在 deviceId = 機器碼 + 名字短雜湊。

**5. Dart 的兩個語言陷阱**
- cascade 不能接箭頭函式:`..onFound = (p) => _log('…')` 的 `..` 會綁到 `_log()` 的回傳值(void),要用大括號 block body。
- top-level 變數是**延遲初始化**:`final _startedAt = DateTime.now();` 是第一次被讀取時才求值,所以 `/status` 永遠顯示「執行 0 分 0 秒」。要在 `main()` 裡明確賦值。

**6. `.bat` 檔不能寫中文**
cmd.exe 讀 `.bat` 用系統 ANSI 編碼(繁中 Windows 是 cp950),不是 UTF-8。中文存成 UTF-8 放進 `.bat`,**指令本身會被拆爛**:

```
'_NAME' 不是內部或外部命令、可執行的程式或批次檔。
```

那是 `set /p "NAME=…「%DEFAULT_NAME%」: "` 被中文位元組切斷後的殘骸。加 `chcp 65001` 沒用,因為 cmd 是一邊執行一邊逐行讀檔。
解法:`win-手動啟動.bat` 只留純 ASCII 當外殼,中文介面搬到 `start.ps1`(存成 **UTF-8 with BOM** —— PowerShell 5.1 沒有 BOM 時會用 cp950 讀檔,一樣亂碼)。

**7. 廣播不要只送 255.255.255.255**
多網卡的機器(Wi-Fi + 乙太 + VPN + Docker)常常只從預設路由那張卡送出去。所以會列出每張網卡、對各自的子網廣播位址也各送一份。
> 已知簡化:假設 /24。嚴謹要讀網路遮罩,Dart 標準庫沒直接提供。

**8. macOS 讀圖片不能只認 PNG**
剪貼簿可能只有 TIFF 沒有 PNGf(Preview 和一些舊 App 就是這樣)。只認 PNGf 會變成「偵測到圖片但讀不出來」。現在先試 PNGf,失敗就抓 TIFF 再用內建的 `sips` 轉成 PNG。

**9. PowerShell 的 UTF-8 有兩種,選錯整個 Windows 端就死了**
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # ✗ 帶 BOM
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false  # ✓ 不帶
```
輸出被導向管線時,帶 BOM 的版本會先吐一個 U+FEFF,於是 Dart 這邊讀到的第一行是 `"﻿TEXT"` 而不是 `"TEXT"`。**而 Dart 的 `trim()` 砍不掉 U+FEFF** —— Unicode 早就把它從「空白字元」改成「格式字元」了。
結果:`probe()` 永遠回傳 null → Windows 完全偵測不到剪貼簿變化 → 從 Windows 複製什麼,對方都收不到。但**寫入照常運作**(那條路不解析 stdout),所以症狀是「貼得上,但傳不出去」,非常難聯想到編碼問題。

**10. HTTP 回錯誤之前要先把 body 收完**
對方可能還在送 5MB 的圖,我們卻直接回 403 就關閉連線。TCP 上會變成「對方還在寫、我方已經關」,送出端看到的是:
```
Connection reset by peer
Connection closed before full header was received
```
真正的原因(被拒絕)完全被藏起來。先 `req.drain()` 再回應,錯誤訊息才會誠實。

**11. `RawDatagramSocket.send()` 的錯誤接不到 —— 而且會把整個程式弄死**
這是整個專案最難查的一個。程式在終端機跑得好好的,設成開機自動啟動之後卻不斷當掉重啟:

```
Unhandled exception:
SocketException: Send failed (OS Error: No route to host, errno = 65)
#2  Discovery._send (src/discovery.dart:94)     ← 這行明明包在 try/catch 裡
```

原因:`send()` 的失敗**不是同步丟出來的**,而是透過 socket 的錯誤串流非同步回報。所以 `try/catch` 包在 `send()` 外面**完全接不到**,錯誤變成「未處理的非同步例外」直接殺掉 isolate。
解法是在 `listen()` 上補 `onError`:

```dart
socket.listen(_onEvent, onError: (e) => ..., cancelOnError: false);
```

觸發條件很陰險:本機有一張**沒有路由的網卡**(VPN、Docker、虛擬機都會造成)時,對它的子網廣播位址送封包就必定噴這個錯。配上 launchd 的 `KeepAlive`(死了就重開),變成完美的無限當機迴圈。

**但補了 `onError` 之後,情況反而更糟。** 程式不當掉了,卻變成「活著但又聾又啞」—— 那個錯誤把整個 socket 弄壞,既收不到也送不出,而且完全沒有徵兆。查了很久才發現:開了 VPN(`utun8: 10.66.66.1`)之後,對 `10.66.66.255` 的那次廣播失敗,順手把同一個 socket 上的收訊也毀了。

最後的解法有三層:
- **收送用兩個不同的 socket**。`_rx` 只負責聽、永遠不 send,所以永遠不會因送出失敗而壞掉;`_tx` 壞了就丟掉重建,收訊完全不受影響。
- **跳過虛擬介面**(`utun` / `ipsec` / `docker` / `bridge` / `vmnet` …),從源頭避免對沒有路由的位址廣播。
- `main()` 外面包 `runZonedGuarded` 當最後保險,並每 15 秒重算一次廣播目標(換 Wi-Fi、VPN 上線、開機時網卡還沒好都需要)。

> 教訓:把例外「吞掉」不等於「處理掉」。安靜地壞掉比大聲地當掉更難查。

**12. launchd 不給你 locale,pbpaste 就默默毀掉你的中文**
背景服務跑起來之後,記錄檔顯示複製的內容變成 `????????`,而且位元組數對不上:

```
有 LANG: 「中文測試abc」 15 bytes
沒 LANG: 「????abc」      7 bytes
```

`pbpaste` / `pbcopy` 的編碼是**看 locale 決定的**。從終端機執行時 shell 早就設好 `LANG=…UTF-8`;但 launchd 給的環境是乾淨的,沒有 `LANG`,pbpaste 就改用 Mac Roman 輸出,把每個中文字換成問號 —— **不報錯,只是安靜地把資料毀掉**。
解法:在 Dart 這邊呼叫子行程時強制帶 `LANG/LC_ALL=en_US.UTF-8`(這樣不管程式怎麼被啟動都對),plist 裡再設一次當雙保險。

**13. 輪詢成本要算清楚**
剪貼簿沒有跨平台的「變更事件」,只能輪詢。macOS 上一次探測約 56ms(`osascript clipboard info` 48ms + `pbpaste` 8ms)。
關鍵設計:`probe()` **只讀摘要不讀內容** —— `clipboard info` 會回傳每種格式的位元組數,那串字本身就能當圖片的 signature,不用把 5MB 的圖搬進記憶體就知道換了沒。
Windows 的 PowerShell 啟動成本高得多,所以預設輪詢間隔拉長到 1500ms。

---

## Step 3.9:多代理地毯式除錯

用 7 個並行的 AI 審查代理掃整個 codebase(每人負責一個領域:並行競態、傳輸協定、UDP 探索、三個平台的剪貼簿實作、主流程、啟動腳本),55 個候選問題逐一經過對抗性驗證,**23 個確認為真**,連同 17 個低嚴重度項目一併修除。挑幾個最有教學價值的:

**A. X11 寫入永久卡死(critical)**
`xclip -i` 讀完 stdin 會 fork 一個常駐子行程去服務 X selection,那個子行程繼承了 stdout/stderr 管線且永遠不關 —— 等管線 EOF 等於永遠等下去。後果鏈:第一則收到的內容 → 寫入卡死 → `_applying` 永遠是 true → 從此連本機複製都偵測不到。**一則訊息殺死整個同步,而且無聲無息。**
解法:寫入類指令只等父行程的結束碼、不等輸出;所有子行程一律加逾時 + 強制擊殺。

**B. 舊內容可以蓋掉新內容(無順序控制)**
連續複製 T1、T2,T1 的連線剛好卡在 TCP 重送 → T2 先到先套用 → 遲到的 T1 把剪貼簿**倒退回舊資料**,而且回音防護還會把這個舊狀態鎖住。修法:每則訊息帶時間戳+序號,收端記錄每台裝置最後套用的位置,舊的直接丟;剪貼簿寫入排進佇列依序執行。

**C. 同名檔案並行傳輸互相寫爛**
`_uniquePath` 原本只「檢查再使用」(TOCTOU):兩個同名傳輸同時到,兩邊都看到「不存在」→ 寫進同一個 `.part` → 交錯損毀,而使用者看到的是一個「成功收到」的檔案。修法:`create(exclusive: true)` 原子性佔位 + `.part` 檔名帶 transferId。

**D. 跨實例檔案增生迴圈(修 bug 修出來的新 bug,被自己的測試抓到)**
同機器的多個實例**共用一個系統剪貼簿、各有各的收件匣**:甲收到檔案寫進剪貼簿 → 乙看到「新複製」(不在乙的收件匣)→ 廣播回去 → 檔名長一個 " (2)" → 每秒增生數個檔案(實測炸出 418 個)。修法:deviceId 前綴就是機器碼,同機器的訊息跳過剪貼簿寫入(剪貼簿本來就是同一份)。

**E. 中文安裝路徑讓 Windows 自動啟動全滅**
啟動用的 `.vbs` 之前存成 ASCII,路徑裡的中文全變 `?` → WScript 找不到檔案,每次登入跳錯誤視窗。修法:`.vbs` 存 UTF-16(WSH 原生格式);裝置名稱改放獨立的 UTF-8 檔案由 `--name-file` 讀,徹底繞開 cmd 的中繼字元(`& | >`)注入和編碼問題。

其他:多檔傳輸逾時改按「最後活動」計(大傳輸不再中途被掃掉)、totalBytes 只算實際要送的檔案、遠端檔名消毒補上 Windows 非法字元與保留名、`--paused` 不再誤寫全機器的暫停旗標、選項解析不再把下一個旗標吃成參數值、`pkill` 錨定路徑開頭(不再誤殺開著 clipsync.dart 的編輯器)、Excel 式「文字+圖片」剪貼簿按來源 App 的偏好判定型別、macOS 複製資料夾不再被誤同步成「資料夾名稱文字」。

---

## 收不到?排錯順序

0. **先跑自我診斷**:`dart run clipsync.dart --doctor`
   完全不碰網路,只測這台電腦的剪貼簿讀寫能不能用。**先把剪貼簿問題和網路問題分開**,不然兩者的症狀一模一樣(都是「沒反應」)。
   有失敗項就加 debug 再跑一次:`CLIPSYNC_DEBUG=1 dart run clipsync.dart --doctor`(Windows 用 `$env:CLIPSYNC_DEBUG=1` 再跑),會印出系統回報的原始錯誤。
1. **開 debug 看封包**:`CLIPSYNC_DEBUG=1 dart run clipsync.dart Alice`
   看得到 TX 但完全沒有 RX → 網路層問題;有 RX 卻沒有「發現裝置」→ 程式邏輯(通常是 deviceId 撞號)。
2. **防火牆**:第一次跑會跳「是否允許網路存取」→ 按允許。Windows 記得勾「私人網路」。要放行**兩個**:UDP 53317(心跳)和 TCP 53318(內容)。
3. **只有心跳通、內容送不到**:看到 `✗ 送不到 Bob:連不上(…)`。連續失敗 3 次程式會提示 —— 幾乎都是防火牆只放行了 UDP。
4. **對方跑舊版**:看到「跑的是舊版 ClipSync」就把整個資料夾重新複製過去。
5. **AP isolation**:很多宿舍/學校 Wi-Fi 會擋裝置互連。最快驗證法:開手機熱點,兩台都連熱點再試。
6. **Linux**:先裝剪貼簿工具 —— Wayland `sudo apt install wl-clipboard`,X11 `sudo apt install xclip`。

> 「手機熱點能通、學校 Wi-Fi 不通」本身就是報告裡很好的一段:為什麼 broadcast 在受管理的網路上會失效,以及你打算怎麼 fallback(mDNS?手動輸入 IP?中繼伺服器?)。

---

## ⚠️ 目前的限制

- **資料夾不同步。** 複製資料夾時會直接跳過(兩個平台行為一致),要傳就先壓縮。
- **Linux 的檔案貼上**只提供標準的 `text/uri-list`;GNOME 檔案管理員要私有的 `x-special/gnome-copied-files` target,暫不支援。
- **完全沒有加密,認證也很弱。** 唯一的防線是「只接受已在裝置清單裡的 IP」,擋得住手滑的鄰居,擋不住有心人:同網段的人可以偽造心跳讓你把他加進清單,然後把任何東西推進你的剪貼簿、或塞檔案到你的 Downloads。**公共 Wi-Fi 上不要跑。** 這正是 Step 4 要解決的事。
- 圖片統一轉成 PNG 傳輸,不保留原始格式(JPEG 會變大)。
- Windows 的圖片 signature 只有寬×高:連續複製兩張**尺寸完全相同**的不同圖片,第二張會被誤判成「沒變」。macOS 有位元組數所以沒這問題。
- 輪詢而非事件驅動。省電上不理想,是純 Dart 拿不到 `NSPasteboard.changeCount` 的代價。
- Windows / Linux 的實作**沒有實機測試過**(開發機是 macOS),邏輯照官方 API 寫,可能還要微調。
- 廣播的子網遮罩假設 /24。

---

## 下一步

3. ~~內容改走 HTTP + 圖片與檔案~~ ✅ 已完成
4. **QR 配對 + 加密** ← 下一個
   - 配對:一台顯示 QR(內含 IP + port + 一組共享密鑰),另一台掃描
   - 加密:用共享密鑰做 AES-GCM,並用 HMAC 驗證來源 → 取代現在那個很弱的 IP 白名單
   - 需要的套件:`cryptography`、`qr_flutter`(這一步開始需要 `pubspec.yaml`)
5. **搬進 Flutter,加 UI 和手機端**
   - `src/` 底下的模組幾乎可以原封不動搬過去,只要換掉 `clipboard.dart` 的實作
   - `PeerRegistry` 改成 `ChangeNotifier`,UI 的裝置清單直接吃它
   - 手機端的限制要先查清楚:**iOS 背景讀剪貼簿基本上不可行,Android 10+ 也擋了背景讀取** —— 這會是報告裡很重要的一個「平台限制」章節,也會直接影響 Step 5 的範圍

其他加分方向:歷史記錄、選擇性同步(只送給指定裝置)、傳輸進度條、mDNS 取代廣播、`dart compile exe` 打包成免安裝執行檔。
