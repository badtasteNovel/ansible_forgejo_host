#!/bin/bash
set -euo pipefail

# 從 wg-infrastructure 的 .conf 裡刪掉一整個 [Peer] 區段——跟
# /srv/network/cluster/remove-peer.sh 同一個道理，見該檔案的完整說明，
# 這裡只是換成 infrastructure 自己的 .conf/interface。要移除哪一個
# peer，用 gum choose 讓使用者互動選，邏輯放在這支腳本裡、不是放在
# Taskfile（Taskfile 的 gum choose 只負責選網段）。
#
# 用法：remove-peer.sh（不帶參數——互動選擇要移除的 peer）

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo ./remove-peer.sh）" >&2
  exit 1
fi

# CONF_PATH 用這支腳本自己所在目錄下的同名檔案，不是 /etc/wireguard 的
# 絕對路徑——道理跟 /srv/network/cluster/remove-peer.sh 一樣，見該檔案
# 的說明。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_PATH="$SCRIPT_DIR/wg-infrastructure.conf"

peer_names=$(grep -oP '^# \K.+' "$CONF_PATH" || true)
if [ -z "$peer_names" ]; then
  echo "錯誤：${CONF_PATH} 裡目前沒有任何 peer 可以移除" >&2
  exit 1
fi
peer_name=$(echo "$peer_names" | gum choose --header "要移除哪個 peer？")
if [ -z "$peer_name" ]; then
  echo "錯誤：沒有選擇任何 peer" >&2
  exit 1
fi
marker="# ${peer_name}"

tmp="$(mktemp)"
awk -v marker="$marker" 'BEGIN{RS=""; ORS="\n\n"} index($0, marker) == 0' "$CONF_PATH" >"$tmp"
mv "$tmp" "$CONF_PATH"

wg syncconf wg-infrastructure <(wg-quick strip "$CONF_PATH")

echo "已移除 ${peer_name}，已經即時套用到 wg-infrastructure，不需要重啟隧道。" >&2
