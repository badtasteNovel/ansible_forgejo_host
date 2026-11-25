#!/bin/bash
set -euo pipefail

# 從 wg-cluster 的 .conf 裡刪掉一整個 [Peer] 區段，立刻套用到正在跑的
# interface（跟 add-peer.sh 一樣用 wg syncconf，不用重啟隧道）。
#
# 要移除哪一個 peer，用 gum choose 讓使用者自己互動選——這段選擇邏輯
# 刻意放在這支腳本裡，不是放在 ~/scripts/wireguard/ 的 Taskfile：
# Taskfile 的 gum choose 只負責「選網段（cluster 還是 infrastructure）」
# 這一題，選好網段之後的事全部交給對應網段自己的 add-peer.sh/
# remove-peer.sh 處理，Taskfile 不需要知道 .conf 的格式、也不用重複寫
# 一次解析 peer 名稱的邏輯。
#
# 這是全新寫的機制，沒有實機跑過。
#
# 用法：remove-peer.sh（不帶參數——互動選擇要移除的 peer）

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo ./remove-peer.sh）" >&2
  exit 1
fi

# CONF_PATH 用這支腳本自己所在目錄下的同名檔案，不是 /etc/wireguard 的
# 絕對路徑——道理跟 add-peer.sh 一樣，見該檔案的說明：這裡其實是透過
# late_command 建的 symbolic link 間接讀寫真正的 .conf。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_PATH="$SCRIPT_DIR/wg-cluster.conf"

# add-peer.sh 幫每個 [Peer] 寫的那行 "# peer-xxxxxxxxxxxxxx" 註解就是
# 這裡拿來給使用者選的名字——不用另外維護一份 peer 清單，.conf 本身就是
# 唯一權威來源。
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

# RS=""（段落模式）把檔案切成一個個以空白行分隔的區塊——[Interface] 自己
# 是一塊，每個 [Peer] 各自一塊（add-peer.sh 寫入時每個 [Peer] 前面都先
# echo 一個空行），用 index() 找出含有目標 peer 名稱註解的那一塊，整塊
# 濾掉，其餘原樣保留、重新接回去。
tmp="$(mktemp)"
awk -v marker="$marker" 'BEGIN{RS=""; ORS="\n\n"} index($0, marker) == 0' "$CONF_PATH" >"$tmp"
mv "$tmp" "$CONF_PATH"

wg syncconf wg-cluster <(wg-quick strip "$CONF_PATH")

echo "已移除 ${peer_name}，已經即時套用到 wg-cluster，不需要重啟隧道。" >&2
