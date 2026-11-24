#!/bin/bash
set -euo pipefail

# 把一個 hostname 對應進 /etc/hosts，指到這台 VM 自己 wg0 介面目前的位址。
#
# 這個名字從來不是真的 DNS record——其他 WireGuard peer 是自己在本機
# hosts 檔案把這個名字指到這台 VM（見 playbook/wsl/add-peer.yml 的
# 說明），但 VM 自己也要能解析這個名字：harbor_finalize（apply.sh 呼叫
# harbor.sh 的最後一步）要在 VM 本機跑 podman login <hostname>，這個連線
# 一樣是走 caddy-proxy（Harbor 自己只在 127.0.0.1 講明文 HTTP，TLS 統一
# 在 caddy-proxy 終止），VM 本機如果沒有這筆 /etc/hosts 對應，這個
# hostname 就只能掉到系統預設 DNS 去查，查不到——實機撞過 "dial tcp:
# lookup harbor.internal on 8.8.8.8:53: no such host"。
#
# 獨立成一支腳本，放在 bootstrap/（跟 services/ 平級），不是放進
# bootstrap/services/、也不是直接寫進 bootstrap-services（Go）的表單流程
# 裡——bootstrap-services 自己的說明寫得很清楚：「Go 負責的部分只剩『表單』
# 這個 shell 做不好的事」，寫 /etc/hosts 是系統層面的操作，不是表單，職責
# 上屬於 shell，跟 apply.sh 底下 harbor.sh/caddy.sh/rustfs.sh 那些「真正
# 做事」的腳本待遇一樣。沒有放進 bootstrap/services/：那個資料夾底下是
# apply.sh 自己 orchestrate 的那條鏈（裝 Harbor/caddy-proxy/RustFS），這支
# 完全獨立在那條鏈之外——是 bootstrap-services（Go）問完表單之後、呼叫
# apply.sh 之前，自己直接呼叫的一個獨立步驟，混進 services/ 裡會讓人誤會
# 它是 apply.sh 那條鏈的一環。
#
# 目標位址直接查 wg0 這個介面目前真正配到的位址，不是靠任何表單值或設定
# 檔去猜——bootstrap-services 的表單裡原本就有一個 WireguardVMAddress
# 欄位，但那個欄位目前唯一的用途只是 apply.sh 最後印給人看的那行網址
# （純粹給人看，沒有任何程式邏輯依賴它），範例文字寫的是 /24 子網（跟
# 「這台 VM 自己的位址」這個說法本身就不一致），直接拿來當這裡的目標
# 位址不可靠。這支腳本本身就是透過 SSH 連進 wg0 執行的（preseed.cfg.j2
# 把 sshd 的 ListenAddress 鎖定在這個介面的位址上），跑到這裡的這一刻
# wg0 保證已經是 up 的狀態，直接問介面本身永遠是最新、最可靠的來源，也
# 跟 caddy-proxy 實際綁定的介面位址天然一致（caddy-proxy 自己也是綁在
# 這個位址上，見 caddy-proxy-install.yml）。
#
# 用法：dns-apply.sh <hostname>

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "用法：dns-apply.sh <hostname>" >&2
  exit 1
fi
hostname="$1"

wg0_address=$(ip -4 -o addr show dev wg0 | grep -oP 'inet \K[0-9.]+')
if [ -z "$wg0_address" ]; then
  echo "錯誤：查不到 wg0 介面目前的位址" >&2
  exit 1
fi

# 先濾掉舊的對應（如果有，例如這支腳本被重複呼叫），避免重複/過期的
# 紀錄——冪等，雖然這支正常只會被呼叫一次，跟呼叫它的 bootstrap-services
# 本身一樣是一次性的。/^#/! 排除註解行，避免註解裡剛好出現這個 hostname
# 字眼被誤判成舊的對應紀錄而整行被刪掉。
sed -i "/^#/!{/[[:space:]]${hostname}\([[:space:]]\|\$\)/d}" /etc/hosts
printf '%s\t%s\n' "$wg0_address" "$hostname" >>/etc/hosts

echo "已把 ${hostname} 對應到 ${wg0_address}（寫進 /etc/hosts）" >&2
