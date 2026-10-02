#!/bin/bash
# 讓 ClipSync 在每次登入時自動於背景啟動(macOS)。
#
# 用的是 launchd 的 LaunchAgent —— macOS 官方的背景服務機制,
# 不需要 sudo,只影響目前這個使用者。
#
# 為什麼要先編譯成執行檔:
#   1. 背景啟動時不會載入你的 shell 設定,dart 很可能不在 PATH 裡
#   2. `dart run` 每次啟動都要重新編譯一次,慢好幾秒
#   3. 編完之後這台電腦就算移除 Dart SDK 也能繼續跑

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.pub-cache/bin:$PATH"
cd "$(dirname "$0")" || exit 1
DIR="$(pwd -P)"
LABEL="com.clipsync.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/ClipSync.log"

printf '\033]0;ClipSync 自動啟動設定\007'
clear 2>/dev/null || true
echo "  ClipSync — 設定開機自動啟動"
echo "  ────────────────────────────────────────"

if ! command -v dart >/dev/null 2>&1; then
  echo
  echo "  ✗ 找不到 Dart SDK,無法編譯執行檔。"
  echo "    請先執行:brew install dart-sdk"
  echo
  read -r -p "  按 Enter 關閉…" _
  exit 1
fi

DEFAULT_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
echo
echo "  這台裝置要叫什麼名字?(另一台電腦會看到這個名字)"
read -r -p "  直接按 Enter 就用「$DEFAULT_NAME」: " NAME
[ -z "$NAME" ] && NAME="$DEFAULT_NAME"

echo
echo "  正在編譯執行檔…"

# ── 為什麼要包成 .app,而不是直接跑裸執行檔 ──────────────────────
# macOS 的「本機網路」隱私權限(核心 NECP)會擋掉連往區網其他裝置的連線。
# 裸執行檔沒有 bundle 身分,系統無法在「系統設定 → 隱私權與安全性 →
# 本機網路」列出它,使用者根本沒有東西可以打開 —— 於是永遠被擋,
# 而且錯誤訊息是誤導人的 "No route to host"。
# 包成 .app + 臨機簽章之後,系統就能以「ClipSync」列出並讓你授權。
APP="$DIR/ClipSync.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ClipSync</string>
    <key>CFBundleDisplayName</key><string>ClipSync</string>
    <key>CFBundleIdentifier</key><string>com.clipsync.app</string>
    <key>CFBundleExecutable</key><string>clipsync</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>3.0</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSUIElement</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ClipSync 需要連線到同一個區域網路中的其他電腦,才能同步剪貼簿。</string>
</dict>
</plist>
PLISTEOF

# 直接編譯進 bundle 裡。不要接管線再判斷結束碼:
# `dart … | sed …` 的 $? 是 sed 的,編譯失敗也會過關,
# 然後 launchd 就一直重啟一個不存在(或舊版)的執行檔。
COMPILE_OUT="$(dart compile exe clipsync.dart -o "$APP/Contents/MacOS/clipsync" 2>&1)"
COMPILE_RC=$?
echo "$COMPILE_OUT" | sed 's/^/    /'
if [ $COMPILE_RC -ne 0 ] || [ ! -x "$APP/Contents/MacOS/clipsync" ]; then
  echo "  ✗ 編譯失敗"
  read -r -p "  按 Enter 關閉…" _
  exit 1
fi

# ⚠ 一定要在編譯**之後**重新簽章。往 Contents/MacOS/ 寫入新的執行檔會
# 破壞 _CodeSignature 的封印,bundle 身分失效 → 退回無法授權的路徑身分,
# 之前授予的權限就白給了。
codesign --force --sign - --identifier com.clipsync.app "$APP" 2>&1 | sed 's/^/    /'
# 保留一份純執行檔,讓 mac-手動啟動.command 之類的手動用法也能跑。
cp -f "$APP/Contents/MacOS/clipsync" "$DIR/clipsync" 2>/dev/null || true

# 選單列 App(macos-menubar/,Swift 寫的原生外皮):右上角圖示,點開是
# 原生選單。已在開發機編譯好,這裡只要簽章、放進應用程式資料夾、
# 設定登入自動開。它透過 127.0.0.1:53320 跟背景服務講話,本身不碰網路。
MENUBAR="$DIR/macos-menubar/ClipSync.app"
if [ -d "$MENUBAR" ]; then
  codesign --force --sign - --identifier com.clipsync.menubar "$MENUBAR" 2>/dev/null
  if [ -w /Applications ]; then MDEST="/Applications"; else MDEST="$HOME/Applications"; mkdir -p "$MDEST"; fi
  rm -rf "$MDEST/ClipSync.app"
  if ditto "$MENUBAR" "$MDEST/ClipSync.app" 2>/dev/null; then
    MPLIST="$HOME/Library/LaunchAgents/com.clipsync.menubar.plist"
    cat > "$MPLIST" <<MENUEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.clipsync.menubar</string>
    <key>ProgramArguments</key>
    <array><string>$MDEST/ClipSync.app/Contents/MacOS/ClipSyncMenuBar</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
MENUEOF
    launchctl bootstrap "gui/$(id -u)" "$MPLIST" 2>/dev/null
    pgrep -x ClipSyncMenuBar >/dev/null 2>&1 || open -a "$MDEST/ClipSync.app" 2>/dev/null
    echo "  ✓ 選單列圖示已裝進 $MDEST,登入時會自動出現在右上角"
  fi
fi

# plist 是 XML,名字裡的 & < > 必須跳脫,否則整個檔案會解析失敗。
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
XNAME="$(esc "$NAME")"
XDIR="$(esc "$DIR")"
XLOG="$(esc "$LOG")"

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$XDIR/ClipSync.app/Contents/MacOS/clipsync</string>
        <!-- 用 --name 而不是位置參數:名字若以 - 開頭(例如有人取名
             "--open"),位置參數會被當成選項解析,具名參數不會。 -->
        <string>--name</string>
        <string>$XNAME</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$XDIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- launchd 給的環境是乾淨的,沒有 LANG。pbpaste/pbcopy 會因此
             改用 Mac Roman 編碼,把中文變成 ????。程式內部也有強制指定,
             這裡再設一次當雙保險。 -->
        <key>LANG</key>
        <string>en_US.UTF-8</string>
        <key>LC_ALL</key>
        <string>en_US.UTF-8</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$XLOG</string>
    <key>StandardErrorPath</key>
    <string>$XLOG</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null
if launchctl load "$PLIST" 2>&1 | sed 's/^/    /'; then
  sleep 2
fi

echo
# ^ 錨定開頭:不錨定的話,「編輯器開著 clipsync.dart」這種指令列也含有
# "$DIR/clipsync" 子字串,pgrep/pkill 會抓錯人。
if pgrep -f "^$DIR/ClipSync.app/Contents/MacOS/clipsync" >/dev/null 2>&1; then
  echo "  ✓ 設定完成,ClipSync 已在背景執行,以後開機會自動啟動。"
else
  echo "  ⚠ 已安裝,但目前沒偵測到執行中的程序。看一下記錄檔:"
  echo "      $LOG"
fi

cat <<INFO

  裝置名稱   $NAME
  記錄檔     $LOG
  ────────────────────────────────────────

  ⚠⚠ 還有最後一步(第一次安裝一定要做)⚠⚠

    系統設定 → 隱私權與安全性 → 本機網路 → 把「ClipSync」打開

  macOS 會擋掉「連往區網其他裝置」的連線,直到你在這裡授權為止。
  沒開的話症狀是:找得到對方、卻永遠「送不到」,錯誤訊息寫
  "No route to host"(看起來像網路壞掉,其實是權限)。

  打開之後要重新啟動服務才會生效(權限是程序啟動時快取的):
      launchctl kickstart -k gui/\$(id -u)/com.clipsync.agent

  常用操作:

    🖥 圖形介面      螢幕右上角的剪貼簿圖示(點開是選單:狀態、暫停、送文字)
    完整控制台      選單裡的「完整控制台」,或點兩下 mac-控制台.command
    看即時記錄      tail -f "$LOG"
    暫停同步        touch ~/.clipsync/paused   (控制台上也有按鈕)
    恢復同步        rm ~/.clipsync/paused
    取消自動啟動    點兩下 mac-取消開機自動啟動.command

  ⚠ 複製密碼之前記得先暫停 —— 不然會直接同步到另一台電腦。
    背景執行時沒有終端機,暫停請用控制台的按鈕(或上面那個檔案開關)。

INFO
read -r -p "  按 Enter 關閉…" _
