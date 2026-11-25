#!/bin/bash
set -euo pipefail

# 在 wg-infrastructure 現有的 .conf 裡現場新增一個 [Peer] 區段，立刻套用到
# 正在跑的 interface（不用重啟隧道、不影響既有連線），然後印出對應的
# client 端設定給使用者直接複製貼上。
#
# 這是全新寫的機制，沒有實機跑過，用之前自己先核對一次輸出的內容。
#
# infrastructure 沒有對應的 build-time Ansible 自動化（跟 cluster 不
# 一樣，見 playbook/control-panel/debian.yml 裡「兩套獨立的 WireGuard
# 身分」那段說明）——這支是 infrastructure 目前唯一的 peer 認領路徑：
# 其他 k3s cluster 的節點要共用這台 VM 上的 Harbor，就是透過這支腳本
# 現場產生一個 peer。

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo ./add-peer.sh）" >&2
  exit 1
fi

# CONF_PATH 用這支腳本自己所在目錄下的同名檔案，不是 /etc/wireguard 的
# 絕對路徑——跟 /srv/network/cluster/add-peer.sh 同一個道理，見該檔案的
# 說明。.key 沒有這層連結，PRIVATE_KEY_FILE 還是直接寫絕對路徑。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_PATH="$SCRIPT_DIR/wg-infrastructure.conf"
PRIVATE_KEY_FILE=/etc/wireguard/infrastructure/wg-infrastructure.key
SUBNET_PREFIX=10.104.0
LISTEN_PORT=51821

# Endpoint 可以用第一個參數覆蓋，沒給的話自動偵測「連到公開 DNS 時，這台
# 主機會用哪個來源位址」當猜測值——這是這台主機自己對外看起來的位址，
# 不保證就是其他機器真正連得到的那個（同一個位址在 NAT 後面、對外部來說
# 可能完全不通），只是個合理的起點，印出來的結果務必自己核對一次，不要
# 不看就直接拿去用——infrastructure 的 peer 通常是另一個 cluster 的節點，
# 更需要確認這個位址真的是對方連得到的（不是同一個實體 LAN 的話，額外
# 要注意路由/NAT 有沒有擋）。
if [ "$#" -ge 1 ]; then
  endpoint_ip="$1"
else
  endpoint_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
  if [ -z "$endpoint_ip" ]; then
    echo "錯誤：自動偵測 Endpoint IP 失敗，請明確帶參數：add-peer.sh <endpoint-ip>" >&2
    exit 1
  fi
  echo "沒有帶參數，自動偵測到的 Endpoint IP 是 ${endpoint_ip}——務必自己確認這是其他機器真正連得到的位址，不對的話重跑並帶上正確的 IP：add-peer.sh <endpoint-ip>" >&2
fi

# 從現有 .conf 裡所有 AllowedIPs = x.x.x.x/32 這種單一位址，抓出已經用掉
# 的最後一個八位元，取最大值 +1 當新 peer 的位址——.1 保留給 VM 自己
# （wg-infrastructure.conf 自己的 Address 那一行），起始值是 2。
last_octet=$(grep -oP "AllowedIPs = ${SUBNET_PREFIX}\.\K\d+(?=/32)" "$CONF_PATH" | sort -n | tail -1 || true)
if [ -z "$last_octet" ]; then
  next_octet=2
else
  next_octet=$((last_octet + 1))
fi
if [ "$next_octet" -gt 254 ]; then
  echo "錯誤：${SUBNET_PREFIX}.0/24 這個網段的位址已經用完（254 個 peer），沒辦法再加" >&2
  exit 1
fi
peer_address="${SUBNET_PREFIX}.${next_octet}"

peer_private_key=$(wg genkey)
peer_public_key=$(echo "$peer_private_key" | wg pubkey)
peer_preshared_key=$(wg genpsk)
server_public_key=$(sudo cat "$PRIVATE_KEY_FILE" | wg pubkey)
peer_name="peer-$(date +%Y%m%d%H%M%S)"

# 直接把新的 [Peer] 區段 append 到真正的 .conf 檔案——這份 .conf 本身就是
# 唯一權威的來源，沒有另外維護一份「peer 清單」的中介檔案。
{
  echo ""
  echo "[Peer]"
  echo "# ${peer_name}"
  echo "PublicKey = ${peer_public_key}"
  echo "PresharedKey = ${peer_preshared_key}"
  echo "AllowedIPs = ${peer_address}/32"
} >>"$CONF_PATH"

# wg syncconf 把新設定套用到正在跑的 interface，不用 down/up 整條隧道
# （現有連線不會被中斷）——wg-quick strip 把 .conf 轉成 wg setconf 格式
# 吃得懂的樣子（去掉 wg-quick 自己才認得的 Address/PostUp 這類欄位）。
wg syncconf wg-infrastructure <(wg-quick strip "$CONF_PATH")

echo "已新增 ${peer_name}（${peer_address}），已經即時套用到 wg-infrastructure，不需要重啟隧道。" >&2
echo "" >&2
echo "=== 把下面這段貼到新 peer 自己的 wg-infrastructure.conf ===" >&2
# client 端的 AllowedIPs 只填 VM 自己的單一位址（/32），不是整個 /24 子網
# ——跟 cluster 那支 add-peer.sh 同一個理由：這個 peer 只需要連到 VM 本身
# （摸到 caddy-proxy），不需要也不該把整個子網的流量都導過來。
cat <<EOF
[Interface]
PrivateKey = ${peer_private_key}
Address = ${peer_address}/24

[Peer]
PublicKey = ${server_public_key}
PresharedKey = ${peer_preshared_key}
AllowedIPs = ${SUBNET_PREFIX}.1/32
Endpoint = ${endpoint_ip}:${LISTEN_PORT}
PersistentKeepalive = 25
EOF
