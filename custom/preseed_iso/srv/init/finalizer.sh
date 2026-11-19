#!/bin/bash
set -euo pipefail

# 只做一件事：podman-network.sh/firewall.sh 都成功之後，把整個 /srv/init
# 砍掉（連自己這支也一起砍——rm -rf 當下這支腳本自己還在跑，Linux 允許
# 刪除一個正在執行中的檔案，跟原本單支 bootstrap-firewall.sh.j2 自己
# `rm -f "$0"` 自刪是同一個原理，只是現在刪的是整個目錄）。
#
# 故意拆成獨立這一支，不是直接放在 firewall.sh 最後一步：firewall.sh 的
# 成功/失敗語意應該只反映「ufw 規則有沒有套用成功」，混進一個跟防火牆
# 邏輯無關的 rm 操作會讓那支腳本的失敗原因變得含糊。這支靠
# finalizer.service 的 After=/Requires=firewall.service 保證只有在
# firewall.service 真的 active（也就是 firewall.sh 跑完、exit code 0）
# 之後才會被排進去跑——firewall.sh 失敗的話，這支根本不會被觸發，
# /srv/init 原樣留著，podman-network.sh/firewall.sh 都還在，可以修完問題
# 再重跑。
#
# 刪掉之後，三個 service 的 ConditionPathExists 全部永久不成立，不會在
# 下次開機被 systemd 再跑一次。

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo /srv/init/finalizer.sh）" >&2
  exit 1
fi

rm -rf /srv/init
