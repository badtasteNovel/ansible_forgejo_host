#!/bin/bash
set -euo pipefail

# 兩個各自固定釘死子網的 podman network——不是不寫、讓 podman 用它自己
# 預設的那個 network（CNI 後端叫 cni-podman0、netavark 後端叫 podman0，
# 兩者都是 podman 網路後端自己的實作細節，哪個後端生效、子網/bridge 介面
# 名稱叫什麼，會隨 podman 版本/預設設定改變，不是這個專案自己控制的值，
# 拿去寫死在 ufw 規則裡風險很高——改了就悄悄失效，沒有任何錯誤訊息）。
# 這裡自己建兩個獨立 network、自己決定子網，firewall.sh 的 ufw 規則就能
# 直接認這兩個我們自己定義、不會因為 podman 升級而改變的子網，不用去猜
# 介面名稱或 podman 預設子網。
#
# 兩個網路、兩個完全不同的用途，刻意分開、不共用一個：
#
# ee-build-network（10.89.0.0/24，gateway 10.89.0.1）：只給 build EE
# image（手寫 Containerfile → podman build，config.sh 的 ensure_ee_image()）
# 用，apt-get/pip 裝套件要連外網。這個網路完全封閉，不跟任何 WireGuard
# 網段打交道——build 這張 image 的過程，從頭到尾不需要連到 wg-cluster/
# wg-basic 上的任何東西，刻意不開那條路由，縮小這個網路的可達範圍。
#
# ansible-builder-network（10.90.0.0/24，gateway 10.90.0.1）：原本是給
# EE image build 用的（名字因此得名），現在改給 ansible-navigator 真正
# 執行 playbook 時的 EE 容器用（見 ansible-navigator.yml 的
# container-options，取代原本的 --network=host）——這支腳本改動之前，
# 這兩件事共用同一個網路；拆開的理由是 harbor-install.yml/
# caddy-proxy-install.yml 跑的時候，容器裡還留著幾個沒有
# delegate_to（純讀取/網路檢查、不是真的操作 podman/systemd 狀態）的
# task（例如 caddy-proxy 的 wait_for 健康檢查）需要摸到
# {{ wireguard_cluster_vm_address }}/{{ wireguard_basic_vm_address }}，
# 讓「建 image 用的網路」跟「跑 playbook 用的網路」共用同一個身分，意味著
# 要把這條 WireGuard 可達性也開給 image build 那個情境，範圍沒有縮到剛好
# ——分成兩個網路之後，只有 ansible-builder-network 這一個需要（也只有
# 它會）被 firewall.sh.j2 開放連到那兩個 WireGuard 位址，ee-build-network
# 完全不受影響，維持原本「只能連到自己的 squid gateway」的封閉範圍。
# harbor/caddy-proxy 這兩個 rootless 使用者的 podman，預設走
# slirp4netns/pasta（使用者自己的 user namespace 裡用 userspace NAT），
# 不是 bridge+veth，跟這兩個網路都無關，不受這支腳本影響。
#
# 各自的 --subnet/--gateway 跟 firewall.sh.j2 的 ufw allow 規則（目的地
# 位址）、config.sh 的 ensure_ee_image()（build container 的 http_proxy/
# https_proxy 指向 10.89.0.1）、ansible-navigator.yml（EE 容器的
# http_proxy/https_proxy 指向 10.90.0.1）共用，改這裡要記得其他幾份一起
# 改（各自獨立執行，沒有共用變數的機制，只能靠註解互相提醒）。--gateway
# 故意明確寫死，不是讓 podman 自己選這個子網裡第一個可用位址（雖然兩者
# 現在算出來的值會一樣）——跟子網本身要固定寫死、不依賴 podman 預設子網
# 是同一個理由，見上面對 cni-podman0/podman0 介面命名的說明。
#
# squid.sh 不綁定這兩個 gateway 位址（監聽所有介面，見該腳本自己的說明
# ——討論過要不要讓 squid 綁死在這個位址上當防禦深度，後來發現這個位址
# 是 podman 內部拿來讓 container 連回 host 用的路由機制，squid/OS 根本
# 不需要特別去認它，綁了只會換來一個跟 netavark 延遲建立 bridge（`podman
# network create` 當下只寫設定檔，實際的 bridge/gateway IP 要等第一個
# container 真正掛上這個 network 才會建出來）耦合的脆弱依賴，卻沒有多換
# 到任何實質防護，拿掉了），所以這支腳本不需要操心 gateway IP 什麼時候
# 真正出現在某個介面上——只要 network 的*設定*存在，firewall.sh.j2 的
# ufw 規則、config.sh/ansible-navigator.yml 的 http_proxy 設定都已經能
# 正常運作，gateway IP 實際出現的時間點（第一個真正掛上這個 network 的
# container 出現時）不影響任何東西。
if ! podman network exists ee-build-network; then
  podman network create --subnet 10.89.0.0/24 --gateway 10.89.0.1 ee-build-network
fi

if ! podman network exists ansible-builder-network; then
  podman network create --subnet 10.90.0.0/24 --gateway 10.90.0.1 ansible-builder-network
fi
