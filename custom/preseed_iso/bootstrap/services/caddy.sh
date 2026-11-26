#!/bin/bash
set -euo pipefail

# 裝 caddy-proxy——apply.sh 等 harbor.sh 把 Harbor 這塊決定完、
# registries.conf.d mirror 設好之後才呼叫這支，這樣這裡要 pull 的 nginx
# image 才吃得到 Harbor 的 pull-through cache。caddy-proxy 是強制功能，不
# 像 harbor.sh 要看 INSTALL_HARBOR 分支，這支沒有條件判斷。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

# /home/harbor、/home/caddy-proxy 兩個目錄已經在 apply.sh 裡集中建好了
# （ansible-navigator.yml 的 volume-mounts 是共用設定，驗證的是清單裡
# 全部的來源路徑，不只是這次用到的那一個），這裡不用再處理。

# mirror-auth.json 這時候可能還不存在（harbor_finalize 要等 caddy-proxy
# 真的啟動之後才會寫，見 harbor.sh 自己的說明，這支正是啟動 caddy-proxy
# 的那一步）——不存在就傳空字串，rootless_podman_user_setup.yml 那邊會
# 處理成「這個環境變數本來就沒設」的效果，不是錯誤。
mirror_auth_b64=""
if [ -f "$MIRROR_AUTH_FILE" ]; then
  mirror_auth_b64=$(base64 -w0 "$MIRROR_AUTH_FILE")
fi

echo "==> 開始安裝 caddy-proxy（ansible-navigator run caddy-proxy-install.yml）..." >&2
run_navigator "$CADDY_PROXY_PLAYBOOK" --extra-vars "mirror_auth_content_b64=${mirror_auth_b64}"
