#!/bin/bash
set -euo pipefail

# 補裝 ansible-builder/ansible-navigator——理論上 late_command 裝機當下
# 就該用 pipx 裝好了（見 preseed.cfg.j2 開頭那兩行 in-target pipx install），
# 但實測在真實硬體上這一步沒有穩定裝好（golden image 建置當下的某個環境
# 因素，例如 late_command 執行當下的網路狀況，原因還沒查清楚），開機後
# ensure_navigator_tools() 的檢查就直接失敗。這支在這裡補一層：一次性
# 開機流程裡，缺了才現場補裝，裝完後面的 ensure_navigator_tools() 檢查
# 才會穩定過。
#
# 跟 config.sh 裡 ensure_navigator_tools()「只檢查、不裝」刻意分工：那支是
# 給所有之後要跑 playbook 的地方共用的輕量檢查（包括 /srv/harbor/rotate/update.sh
# 這種事後維運腳本），不該帶安裝的副作用；這支只在第一次開機的 bootstrap
# 流程跑一次，跑完連自己都會被刪掉。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 root 執行這支程式" >&2
  exit 1
fi

if command -v ansible-navigator >/dev/null 2>&1 && command -v ansible-builder >/dev/null 2>&1; then
  echo "==> ansible-builder/ansible-navigator 已經存在，不重裝"
  exit 0
fi

echo "==> golden image 沒帶到 ansible-builder/ansible-navigator，現場用 pipx 補裝..."
pipx install ansible-builder
pipx install ansible-navigator
