#!/bin/bash
set -euo pipefail

# add-peer.sh 只處理了一半——那支是跑在 basic host 那邊，幫新 peer 產生
# 金鑰/IP、寫進 host 自己的 .conf、印出一段「貼到新 peer 自己的
# wg-basic.conf」的設定。這支是另一半：真正跑在新 peer（這台，
# is_basic_host=false 的 VM）自己身上，把貼過來的那段設定寫成
# /etc/wireguard/basic/wg-basic.conf、建 wg-basic.service、enable+start，
# 讓這台 VM 真的變成 10.104.0.0/24 網段裡的一個 IP。
#
# is_basic_host=false 的 VM 在 build 時完全沒有 wg-basic 的任何東西
# （preseed.cfg.j2 整段用 is_basic_host 包起來）——這是故意的：這個網段
# 只有一個 host，新 VM 要先存在、開機、才知道要連去哪個 Endpoint，build
# 時機根本還沒到。這支腳本就是那個「事後才補上去」的動作，跟
# playbook/wsl/add-peer.yml 幫 WSL2 控制端加入 wg-cluster 是同一個道理，
# 只是 basic 這邊從頭到尾都沒有對應的 Ansible 自動化（見
# playbook/control-panel/debian.yml 裡「兩套獨立的 WireGuard 身分」那段
# 說明），整條路徑刻意維持純 shell script。
#
# 這是全新寫的機制，沒有實機跑過，用之前自己先確認一次 wg-basic.conf
# 的內容跟 wg-basic.service 的狀態。
#
# 用法：sudo ./join.sh，接著把 add-peer.sh 印出來的那一整段
# （[Interface] 到最後一行 PersistentKeepalive）貼進來，貼完按 Ctrl-D。

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo ./join.sh）" >&2
  exit 1
fi

CONF_PATH=/etc/wireguard/basic/wg-basic.conf
SERVICE_PATH=/etc/systemd/system/wg-basic.service

# 不靜默覆蓋——這台 VM 可能已經加入過、連線也正在用，貼錯一次重跑會
# 直接打斷現有隧道。要重新加入，請自己先確認再手動刪掉舊的 .conf。
if [ -f "$CONF_PATH" ]; then
  echo "錯誤：${CONF_PATH} 已經存在，這台 VM 看起來已經加入過 wg-basic——如果要重新加入，請先自己確認現有連線不需要了，手動刪掉這個檔案再重跑" >&2
  exit 1
fi

echo "請貼上 add-peer.sh 印出來的那一整段（從 [Interface] 到 PersistentKeepalive），貼完按 Ctrl-D：" >&2
pasted="$(cat)"

if ! grep -q '^\[Interface\]$' <<<"$pasted" || ! grep -q '^\[Peer\]$' <<<"$pasted"; then
  echo "錯誤：貼進來的內容看起來不完整，沒看到 [Interface] 跟 [Peer] 兩個區段，沒有寫入任何檔案" >&2
  exit 1
fi

mkdir -p /etc/wireguard/basic
chmod 700 /etc/wireguard/basic
printf '%s\n' "$pasted" >"$CONF_PATH"
chmod 600 "$CONF_PATH"

# /srv/network/basic/wg-basic.conf 這個符號連結，跟 host 端
# （preseed.cfg.j2 的 late_command）建的那個是同一個道理——讓這個目錄下
# 的 show.sh（這台 VM 自己也有，整個 srv/ 樹是無條件複製進每台 VM 的）
# 能用自己所在目錄的相對路徑讀到這份 .conf，不用另外硬寫
# /etc/wireguard 的絕對路徑。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ln -sf "$CONF_PATH" "$SCRIPT_DIR/wg-basic.conf"

# unit 定義跟 host 端 build 時（preseed.cfg.j2）寫的那份完全一樣，只是
# 這裡是在 runtime 現場建，不是裝機時烘焙——兩邊要維持一致，有一邊改了
# 另一邊要記得一起改。
echo '[Unit]' >"$SERVICE_PATH"
echo 'Description=WireGuard (basic, 10.104.0.0/24 -- shared infra reachable across multiple clusters, e.g. Harbor)' >>"$SERVICE_PATH"
echo 'After=network.target' >>"$SERVICE_PATH"
echo '[Service]' >>"$SERVICE_PATH"
echo 'Type=oneshot' >>"$SERVICE_PATH"
echo 'RemainAfterExit=yes' >>"$SERVICE_PATH"
echo "ExecStart=/usr/bin/wg-quick up ${CONF_PATH}" >>"$SERVICE_PATH"
echo "ExecStop=/usr/bin/wg-quick down ${CONF_PATH}" >>"$SERVICE_PATH"
echo '[Install]' >>"$SERVICE_PATH"
echo 'WantedBy=multi-user.target' >>"$SERVICE_PATH"

systemctl daemon-reload
systemctl enable --now wg-basic.service

echo "已加入 wg-basic，這台 VM 現在的位址：" >&2
ip -4 -o addr show dev wg-basic | grep -oP 'inet \K[0-9.]+' >&2
