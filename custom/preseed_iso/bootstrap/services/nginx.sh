#!/bin/bash
set -euo pipefail

# 裝 nginx-proxy——apply.sh 等 harbor.sh 把 Harbor 這塊決定完、
# registries.conf.d mirror 設好之後才呼叫這支，這樣這裡要 pull 的 nginx
# image 才吃得到 Harbor 的 pull-through cache。nginx-proxy 是強制功能，不
# 像 harbor.sh 要看 INSTALL_HARBOR 分支，這支沒有條件判斷。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

# 跟 harbor.sh 建 /home/harbor 同一個道理：ansible-navigator.yml 掛了
# /home/nginx-proxy，ansible-navigator 自己在容器啟動前就檢查這個路徑存不
# 存在，nginx-proxy 這個使用者還沒被 nginx-proxy-install.yml 的 useradd 建
# 出來之前，host 上要先有這個目錄。nginx-proxy 是 debian.yml 寫死的常數。
mkdir -p /home/nginx-proxy

echo "==> 開始安裝 nginx-proxy（ansible-navigator run nginx-proxy-install.yml）..." >&2
run_navigator "$NGINX_PROXY_PLAYBOOK"
