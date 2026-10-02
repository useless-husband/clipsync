#!/bin/bash
# 取消 ClipSync 的開機自動啟動(macOS),並停掉目前在背景跑的那個。

cd "$(dirname "$0")" || exit 1
DIR="$(pwd -P)"
LABEL="com.clipsync.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

printf '\033]0;ClipSync 移除自動啟動\007'
clear 2>/dev/null || true
echo "  ClipSync — 取消開機自動啟動"
echo "  ────────────────────────────────────────"
echo

if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
  launchctl unload "$PLIST" 2>/dev/null
  rm -f "$PLIST"
  echo "  ✓ 已移除自動啟動設定"
else
  echo "  (本來就沒有設定自動啟動)"
fi

# ⚠ pgrep/pkill 是大小寫敏感的。之前寫成 "^$DIR/clipsync" 抓不到
# ".../ClipSync.app/Contents/MacOS/clipsync"(C 是大寫)—— 結果是移除腳本
# 印出「已停止」,但背景服務其實還在跑、還在同步剪貼簿。兩種路徑都要涵蓋。
KILLED=0
pkill -f "^$DIR/ClipSync.app/Contents/MacOS/clipsync" 2>/dev/null && KILLED=1
pkill -f "^$DIR/clipsync( |$)" 2>/dev/null && KILLED=1
sleep 1
if pgrep -f "$DIR/.*clipsync" >/dev/null 2>&1; then
  echo "  ⚠ 還有 ClipSync 程序在跑,強制結束"
  pkill -9 -f "$DIR/.*clipsync" 2>/dev/null
elif [ "$KILLED" = 1 ]; then
  echo "  ✓ 已停止背景執行的 ClipSync"
fi

echo
echo "  以後要用的話,點兩下 mac-手動啟動.command 手動開,"
echo "  或再點一次 mac-設定開機自動啟動.command 重新設定自動啟動。"
echo
read -r -p "  按 Enter 關閉…" _
