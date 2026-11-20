#!/bin/bash
set -euo pipefail

# 裝 nginx-proxy——apply.sh 等 harbor.sh 把 Harbor 這塊決定完、
# registries.conf.d mirror 設好之後才呼叫這支，這樣這裡要 pull 的 nginx
# image 才吃得到 Harbor 的 pull-through cache。nginx-proxy 是強制功能，不
# 像 harbor.sh 要看 INSTALL_HARBOR 分支，這支沒有條件判斷。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

# /home/harbor、/home/nginx-proxy 兩個目錄已經在 apply.sh 裡集中建好了
# （ansible-navigator.yml 的 volume-mounts 是共用設定，驗證的是清單裡
# 全部的來源路徑，不只是這次用到的那一個），這裡不用再處理。

echo "==> 開始安裝 nginx-proxy（ansible-navigator run nginx-proxy-install.yml）..." >&2
run_navigator "$NGINX_PROXY_PLAYBOOK"
