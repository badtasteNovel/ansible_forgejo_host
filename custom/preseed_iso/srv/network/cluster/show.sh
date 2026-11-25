#!/bin/bash
set -euo pipefail

# 顯示 wg-cluster 自己的公鑰——從私鑰檔案現場用 wg pubkey 推算，不是另外
# 存一份：公鑰本來就能從私鑰百分之百推算出來，沒必要維護兩份可能兜不起來
# 的副本。.key 檔案是 root:root、mode 600（見 preseed.cfg.j2 的
# late_command），這裡用 sudo 讀，不要求整支腳本都要以 root 身份執行。
#
# 有 clipboard 工具的話順便複製一份，方便直接貼給別人——這台機器是遠端
# headless 的 Debian VM，正常情況下不會有 xclip/wl-copy 這類桌面環境工具，
# 這裡只是防呆式地檢查，沒裝就單純跳過，不會因為沒有這些工具而失敗。

PRIVATE_KEY_FILE=/etc/wireguard/cluster/wg-cluster.key

public_key=$(sudo cat "$PRIVATE_KEY_FILE" | wg pubkey)

echo "$public_key"

if command -v xclip >/dev/null 2>&1; then
  printf '%s' "$public_key" | xclip -selection clipboard
  echo "（已複製到 clipboard，xclip）" >&2
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$public_key" | wl-copy
  echo "（已複製到 clipboard，wl-copy）" >&2
elif command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "$public_key" | clip.exe
  echo "（已複製到 clipboard，clip.exe）" >&2
fi
