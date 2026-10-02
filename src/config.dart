import 'dart:io';

// 全域常數。之後搬進 Flutter 時,這裡大多會變成使用者可以在設定頁調的值。

const String kApp = 'clipsync';

/// v1 = 純 UDP 文字;v2 = 內容改走 HTTP;v3 = 支援圖片與檔案(二進位 body)
const int kProtocolVersion = 3;

/// UDP:只負責「我在這」的心跳廣播,封包很小,永遠不會超過 MTU。
const int kDiscoveryPort = 53317;

/// TCP:剪貼簿內容走這裡。UDP 有 64KB 上限,複製一篇長文就爆了。
const int kContentPort = 53318;

/// 網頁控制台(圖形介面)。**只綁 127.0.0.1**:
/// 瀏覽器開 http://127.0.0.1:53320 就能看狀態、按暫停、送文字,
/// 但區網上其他電腦完全碰不到這個埠 —— 控制自己電腦的權力不該開放給整個區網。
/// 選 53320 而不是 53319,是因為說明文件教人用 53319 開同機第二個實例。
const int kUiPort = 53320;

/// 內容的中繼資料放在這個 HTTP 標頭裡(base64 過的 JSON),body 則是原始位元組。
/// 不把圖片塞進 JSON 是因為 base64 會膨脹 33%,而且要先整個讀進記憶體。
const String kMetaHeader = 'x-clipsync-meta';

const Duration kHeartbeatInterval = Duration(seconds: 2);

/// 多久沒收到心跳就當對方離線。
///
/// 原本是 10 秒,實測發現太短:UDP 廣播本來就會掉,實測某台 Windows 在
/// 60 秒內只有 3 次心跳穿過來(正常應該 30 次),於是裝置清單一直在
/// 「發現 → 離線 → 發現」之間跳動。而清單一旦少了對方,他推內容過來就會
/// 被當成陌生 IP 擋掉 —— 使用者看到的是「同步失敗」,完全聯想不到是心跳問題。
///
/// 拉長到 25 秒,再配合「單播心跳」與「收到內容就更新 lastSeen」,
/// 才能容忍廣播的先天不可靠。
const Duration kPeerTimeout = Duration(seconds: 25);

/// 同一台裝置的位址要「黏」多久才准換。
///
/// 一台電腦同時插網路線又開 Wi-Fi、而且兩張網卡都在同一個網段時
/// (例如 en0 = 192.168.0.23、en1 = 192.168.0.171),心跳會從**兩個**
/// 來源位址交錯送達。deviceId 是同一個,所以對方會把這台裝置的位址
/// 每兩秒改寫一次,清單上看起來就是兩個 IP 不停互跳。
///
/// 更糟的是這不只是畫面難看:送內容前剛好換成那張沒有預設路由的網卡,
/// 就會送失敗,而且下一秒又換回來,錯誤看起來像是隨機發生的。
///
/// 對策是「現用位址優先」:只要現用位址在這段時間內還有心跳,
/// 其他位址一律忽略。真的換網路(舊位址沒聲音了)才會切過去。
const Duration kAddressStickiness = Duration(seconds: 8);

/// 剪貼簿沒有跨平台的「變更事件」,只能輪詢。
/// macOS 上一次探測約 56ms(osascript 48ms + pbpaste 8ms);
/// Windows 的 PowerShell 啟動成本高很多(每次數百毫秒),所以預設拉長。
Duration get kClipboardPollInterval => Platform.isWindows
    ? const Duration(milliseconds: 1500)
    : const Duration(milliseconds: 700);

/// 自己寫入剪貼簿之後的「靜音期」——回音防護的第二道保險。
/// 有些剪貼簿管理員(Maccy、Ditto…)會在你寫入後再改寫一次內容。
const Duration kEchoSuppressWindow = Duration(milliseconds: 500);

// ── 各種內容的大小上限 ──────────────────────────────────────────
/// 純文字。
const int kMaxTextBytes = 4 * 1024 * 1024;

/// 圖片(PNG)。截圖通常幾百 KB,32MB 已經很寬鬆。
const int kMaxImageBytes = 32 * 1024 * 1024;

/// 單一檔案。
const int kMaxFileBytes = 200 * 1024 * 1024;

/// 一次傳輸(可能多檔)的總量。自動收下幾 GB 的檔案是很糟的預設行為。
const int kDefaultMaxTransferBytes = 512 * 1024 * 1024;

/// 多檔傳輸沒收齊就放著不管會漏記憶體/暫存檔,**閒置**超過這個時間就清掉。
/// 注意是「距離最後一次收到資料」而不是「距離開始」—— 幾百 MB 的多檔傳輸
/// 本來就可能跑超過兩分鐘,以開始時間計算會把傳到一半的正常傳輸掃掉。
const Duration kTransferTimeout = Duration(minutes: 2);

const Duration kSendTimeout = Duration(seconds: 10);

/// 傳大檔時 HTTP 要等久一點。
const Duration kFileSendTimeout = Duration(minutes: 10);

/// 暫停旗標檔。這個檔案存在 = 暫停同步。
///
/// 為什麼用檔案而不是只用記憶體裡的變數:開機自動啟動時程式跑在背景,
/// 根本沒有終端機可以打 /pause。用檔案當開關的話,背景模式也能暫停
/// (而且重開機後狀態還在,不會忘了自己按過暫停)。
String pauseFlagPath() {
  final sep = Platform.pathSeparator;
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home$sep.clipsync${sep}paused';
}

/// 收到的檔案放哪裡。
String defaultInboxDir() {
  final sep = Platform.pathSeparator;
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home${sep}Downloads${sep}ClipSync';
}
