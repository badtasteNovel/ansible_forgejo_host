#!/bin/bash
set -euo pipefail

# 把一個 hostname 對應進 /etc/hosts，指到這台 VM 自己 wg-cluster 介面目前的位址。
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
# 目標位址直接查介面目前真正配到的位址，不是靠任何表單值或設定檔去猜。
# 優先用 wg-basic（如果這台 VM 有的話）：這支腳本目前唯一的呼叫情境是
# harbor_hostname，Harbor 概念上是 basic 網段（多個 cluster 共用的基礎
# 設施，見 debian.yml 兩套 WireGuard 身分的說明）的東西，不是這個 cluster
# 自己的——VM 本機對 Harbor 的連線走 wg-basic，才跟其他 cluster 將來連
# 這個 Harbor 走的是同一條路徑（同一個 caddy-proxy 綁定位址、同一條
# firewall.sh.j2 的 REDIRECT 規則），順便在裝機當下就驗證那條路徑是通的，
# 不用等到真的有其他 cluster 接上來才第一次測到。wg-basic 不是每台 VM
# 都有（只有 is_basic_host 的那台才會產生這個介面），所以用
# `ip link show` 先確認介面存不存在，不存在就照舊退回 wg-cluster——這支
# 腳本本身就是透過 SSH 連進 wg-cluster 執行的（preseed.cfg.j2 把 sshd 的
# ListenAddress 鎖定在這個介面的位址上），跑到這裡的這一刻 wg-cluster
# 保證已經是 up 的狀態，一定能當退回的選項。bootstrap-services 的表單
# 原本有一個 WireguardVMAddress 欄位讓使用者自己填，後來發現唯一用途只是
# apply.sh 最後印給人看的那行網址，沒有任何程式邏輯依賴它，改成這裡同一套
# 「直接查介面」的做法之後，那個欄位整題拿掉了（見 apply.sh 自己的說明）。
#
# 用法：dns-apply.sh <hostname>

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  echo "用法：dns-apply.sh <hostname>" >&2
  exit 1
fi
hostname="$1"

if ip link show wg-basic >/dev/null 2>&1; then
  target_interface=wg-basic
else
  target_interface=wg-cluster
fi
target_address=$(ip -4 -o addr show dev "$target_interface" | grep -oP 'inet \K[0-9.]+')
if [ -z "$target_address" ]; then
  echo "錯誤：查不到 ${target_interface} 介面目前的位址" >&2
  exit 1
fi

# 先濾掉舊的對應（如果有，例如這支腳本被重複呼叫），避免重複/過期的
# 紀錄——冪等，雖然這支正常只會被呼叫一次，跟呼叫它的 bootstrap-services
# 本身一樣是一次性的。/^#/! 排除註解行，避免註解裡剛好出現這個 hostname
# 字眼被誤判成舊的對應紀錄而整行被刪掉。
sed -i "/^#/!{/[[:space:]]${hostname}\([[:space:]]\|\$\)/d}" /etc/hosts
printf '%s\t%s\n' "$target_address" "$hostname" >>/etc/hosts

echo "已把 ${hostname} 對應到 ${target_address}（${target_interface}，寫進 /etc/hosts）" >&2
