#!/bin/bash
set -euo pipefail

# 裝 RustFS——跟 caddy.sh 一樣沒有條件判斷（RustFS 是強制功能，不是
# INSTALL_HARBOR 那種使用者表單選出來的分支）。apply.sh 排在 harbor_finalize
# 之後才呼叫這支：RustFS 本身不依賴 Harbor/caddy-proxy 任何東西（它只綁
# 127.0.0.1，不需要先知道 caddy-proxy 的 CA），純粹是把新服務接在既有流程
# 最後面，不打擾既有 Harbor 那幾步互相依賴的順序。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

# /home/rustfs 已經在 apply.sh 裡跟 /home/harbor、/home/caddy-proxy 一起
# 集中建好了（ansible-navigator.yml 的 volume-mounts 是共用設定，驗證的是
# 清單裡全部的來源路徑，不只是這次用到的那一個），這裡不用再處理。

echo "==> 開始安裝 RustFS（ansible-navigator run rustfs-install.yml）..." >&2
run_navigator "$RUSTFS_PLAYBOOK"

# 啟用 NAS 備份排程這個動作故意留在這裡做，不是 rustfs-install.yml 裡的
# task——rustfs-install.yml 只負責把 service/timer 這兩個 unit 檔案寫好、
# daemon-reload（見該檔案自己的說明），「啟動」是這支腳本自己接手的最後
# 一步，呼應「rustfs.sh 跑完以後才啟動 cronjob」這個流程切分。
echo "==> 啟動 RustFS 備份到 NAS 的排程（rustfs-backup.timer，每天 03:30）..." >&2
systemctl enable --now rustfs-backup.timer
