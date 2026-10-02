#!/bin/bash
# ClipSync 啟動器(macOS)—— 在 Finder 裡點兩下就會開終端機跑起來。
#
# 小坑:從 Finder 點兩下時,shell 是「非互動式」的,不會載入 ~/.zshrc,
# 所以 Homebrew 裝的 dart 可能不在 PATH 裡 → 這裡手動補上常見路徑。
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.pub-cache/bin:$PATH"

cd "$(dirname "$0")" || exit 1
printf '\033]0;ClipSync\007'   # 設定終端機視窗標題

clear 2>/dev/null || true
echo "  ClipSync — 區網剪貼簿同步"
echo "  ────────────────────────────────────────"

if ! command -v dart >/dev/null 2>&1; then
  echo
  echo "  ✗ 找不到 Dart SDK。"
  echo
  echo "  請先在終端機執行:"
  echo "      brew install dart-sdk"
  echo
  echo "  (沒有 Homebrew 的話,先去 https://brew.sh 安裝)"
  echo
  read -r -p "  按 Enter 關閉…" _
  exit 1
fi

DEFAULT_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
echo
echo "  這台裝置要叫什麼名字?(其他裝置會看到這個名字)"
read -r -p "  直接按 Enter 就用「$DEFAULT_NAME」: " NAME
[ -z "$NAME" ] && NAME="$DEFAULT_NAME"

echo
echo "  提醒:第一次跑如果跳出「是否允許接受傳入的網路連線」,要按【允許】。"
echo "  結束請打 /quit 按 Enter,或按 Ctrl+C。"
echo

# --name 而不是位置參數:名字開頭是 - 時位置參數會被誤認成選項。
exec dart run clipsync.dart --name "$NAME"
