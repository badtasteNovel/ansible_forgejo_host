#!/bin/bash
set -euo pipefail

# 顯示 wg-basic 自己的公鑰——跟 /srv/network/cluster/show.sh 同一個
# 道理，見該檔案的完整說明，這裡只是換成 basic 自己的私鑰檔案。

PRIVATE_KEY_FILE=/etc/wireguard/basic/wg-basic.key

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
