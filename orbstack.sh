#!/bin/bash
# OrbStack Linux 機器啟動器
# 用法:  ./orbstack.sh <os> [模式]
#   <os>    OS 目錄名稱 (該目錄下要有 orbstack/cloud-init.yaml), 例如 ubuntu
#   模式    (空)    建立 (若不存在) 並進入 shell
#           ssh     以 X11 轉發連線 (tkinter 視窗顯示在 Mac 的 XQuartz); 連 <os>.orb.local, 客體要有 sshd 和你的公鑰
#           stop    停止
#           delete  刪除機器
#           ip      顯示機器網址
#           provision  對現有機器補裝套件 (預設機器沒套用 cloud-init 時用)
# 機器名稱 = <os> (OrbStack 首次啟動會自動建 ubuntu, 直接沿用)
set -euo pipefail
cd "$(dirname "$0")"
OS="${1:-}"; MODE="${2:-}"
[ -n "$OS" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 1; }
OS="${OS%/}"; CI="$OS/orbstack/cloud-init.yaml"; NAME="$OS"
[ -f "$CI" ] || { echo "找不到 $CI" >&2; exit 1; }
command -v orb >/dev/null || { echo "請先 brew install orbstack" >&2; exit 1; }

case "$MODE" in
  "")     orb list -q | grep -qx "$NAME" || orb create --user-data "$CI" "${OS}:26.04" "$NAME"
          exec orb -m "$NAME" ;;
  # orb 內建的 ssh 入口 (<機器>@orb) 不轉發 X11, 要連客體自己的 sshd (需 openssh-server 與已放入的公鑰)
  ssh)    exec ssh -X "$USER@$NAME.orb.local" ;;
  stop)   orb stop "$NAME" ;;
  delete) orb delete -f "$NAME" ;;
  provision) orb -m "$NAME" -u root bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y $(sed -n '/^packages:/,$p' "$PWD/$CI" | sed -n 's/^  - \([^ #]*\).*/\1/p' | tr '\n' ' ')" ;;
  ip)     echo "$NAME.orb.local" ;;
  *)      echo "未知模式: $MODE" >&2; exit 1 ;;
esac
