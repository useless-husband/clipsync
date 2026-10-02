#!/bin/bash
# 打開 ClipSync 的網頁控制台(macOS)。
#
# 控制台是程式內建的網頁(http://127.0.0.1:53320,只有這台電腦看得到)。
# 這個腳本做三件事:確認程式在跑(沒跑就幫忙拉起來)→ 用瀏覽器打開。

cd "$(dirname "$0")" || exit 1
URL="http://127.0.0.1:53320"
LABEL="com.clipsync.agent"

up() { curl -s --max-time 1 -o /dev/null "$URL/api/status"; }

if ! up; then
  # 沒在跑?有裝自動啟動的話,直接請 launchd 把它叫起來。
  if [ -f "$HOME/Library/LaunchAgents/$LABEL.plist" ]; then
    launchctl kickstart "gui/$(id -u)/$LABEL" 2>/dev/null
    for _ in 1 2 3 4 5 6; do
      sleep 1
      up && break
    done
  fi
fi

if up; then
  open "$URL"
else
  printf '\033]0;ClipSync 控制台\007'
  clear 2>/dev/null || true
  echo
  echo "  ✗ ClipSync 沒有在執行,控制台打不開。"
  echo
  echo "    請先點兩下 mac-手動啟動.command(手動開一次),"
  echo "    或 mac-設定開機自動啟動.command(設定開機自動啟動)。"
  echo
  read -r -p "  按 Enter 關閉…" _
fi
