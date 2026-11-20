#!/bin/bash
set -euo pipefail

# 把這台 VM 上的 Harbor 升級到指定版本——跟 bootstrap-services 不一樣，
# 這是日常維運工具，不是一次性的，跑完不會自我刪除，可以重複執行。真正
# 做事的是 harbor-update.yml（跟這支放同一個資料夾），這支只負責：檢查
# 參數、確保 ansible-navigator/EE image 都還在，然後呼叫
# ansible-navigator run。
#
# 只處理「換版本、podman-compose up -d 重建容器」這件事本身，不動 robot
# 帳號/密碼（維持原本的 registries.conf.d mirror/mirror-auth.json 繼續
# 有效），細節見 harbor-update.yml 開頭的說明。
#
# 用法：sudo /srv/harbor/rotate/update.sh v2.16.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 root 執行這支程式" >&2
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "用法：sudo $0 <harbor_version>（例如 v2.16.0）" >&2
  exit 1
fi
harbor_version="$1"

ensure_navigator_tools
ensure_ee_image

run_navigator "$SCRIPT_DIR/harbor-update.yml" --extra-vars "harbor_version=${harbor_version}"
