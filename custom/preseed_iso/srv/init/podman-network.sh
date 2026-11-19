#!/bin/bash
set -euo pipefail

# 給 EE image build（ansible-builder build → podman build）專用的一個 podman
# network，固定釘死一個子網——不是不寫、讓 podman 用它自己預設的那個
# network（CNI 後端叫 cni-podman0、netavark 後端叫 podman0，兩者都是 podman
# 網路後端自己的實作細節，哪個後端生效、子網/bridge 介面名稱叫什麼，會隨
# podman 版本/預設設定改變，不是這個專案自己控制的值，拿去寫死在 ufw 規則
# 裡風險很高——改了就悄悄失效，沒有任何錯誤訊息）。這裡自己建一個獨立
# network、自己決定子網，firewall.sh 的 ufw 規則就能直接認這個我們自己定義、
# 不會因為 podman 升級而改變的子網，不用去猜介面名稱或 podman 預設子網。
#
# 只有這一個用途：ansible-builder build 這一步（build EE image 期間
# microdnf/pip 要連外網裝套件）要用。其他地方都不需要靠這個：
# - ansible-navigator 真正跑 playbook 時，EE 容器用的是 --network=host（見
#   ansible-navigator.yml），走的是 host 自己的網路，不會經過任何 bridge；
# - harbor/nginx-proxy 這兩個 rootless 使用者的 podman，預設走
#   slirp4netns/pasta（使用者自己的 user namespace 裡用 userspace NAT），
#   不是 bridge+veth，一樣不會受這條規則影響。
#
# --subnet 10.90.0.0/24、--gateway 10.90.0.1 這兩個值跟 firewall.sh.j2
# 的 ufw allow 規則（目的地位址）、config.sh 的 ensure_ee_image()（build
# container 的 http_proxy/https_proxy 指向這個 gateway）共用，改這裡要
# 記得兩份一起改（各自獨立執行，沒有共用變數的機制，只能靠註解互相
# 提醒）。--gateway 故意明確寫死，不是讓 podman 自己選這個子網裡第一個
# 可用位址（雖然兩者現在算出來的值會一樣）——跟子網本身要固定寫死、不
# 依賴 podman 預設子網是同一個理由，見上面對 cni-podman0/podman0 介面
# 命名的說明。
#
# squid.sh 不綁定這個 gateway 位址（監聽所有介面，見該腳本自己的說明
# ——討論過要不要讓 squid 綁死在這個位址上當防禦深度，後來發現這個位址
# 是 podman 內部拿來讓 container 連回 host 用的路由機制，squid/OS 根本
# 不需要特別去認它，綁了只會換來一個跟 netavark 延遲建立 bridge（`podman
# network create` 當下只寫設定檔，實際的 bridge/gateway IP 要等第一個
# container 真正掛上這個 network 才會建出來）耦合的脆弱依賴，卻沒有多換
# 到任何實質防護，拿掉了），所以這支腳本不需要操心 gateway IP 什麼時候
# 真正出現在某個介面上——只要 network 的*設定*存在，firewall.sh.j2 的
# ufw 規則、config.sh 的 http_proxy 設定都已經能正常運作，gateway IP
# 實際出現的時間點（ensure_ee_image() 第一次真正 build 的時候）不影響
# 任何東西。
if ! podman network exists ansible-builder-network; then
  podman network create --subnet 10.90.0.0/24 --gateway 10.90.0.1 ansible-builder-network
fi
