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
# --subnet 10.90.0.0/24 這個值跟 firewall.sh.j2 的 ufw allow 規則、squid.sh
# 的 squid.conf 共用，改這裡要記得三份一起改（各自獨立執行，沒有共用變數
# 的機制，只能靠註解互相提醒）。
#
# --gateway 10.90.0.1 故意明確寫死，不是讓 podman 自己選這個子網裡第一個
# 可用位址當 gateway（雖然兩者現在算出來的值會一樣）：squid.sh 裝的正向
# 代理要綁定在一個固定位址上給 build container 連，如果不寫死、改成依賴
# podman「預設挑第一個可用位址」這個隱性行為，日後 podman 版本更新一旦
# 改了這個預設，squid 綁定的位址就會悄悄跟 gateway 實際位址不一致，跟
# 子網本身要固定寫死、不依賴 podman 預設子網是同一個理由（見上面對
# cni-podman0/podman0 介面命名的說明）。
if ! podman network exists ansible-builder-network; then
  podman network create --subnet 10.90.0.0/24 --gateway 10.90.0.1 ansible-builder-network
fi
