#!/bin/bash
set -euo pipefail

# 只做一件事：podman-network.sh/firewall.sh/software-install.sh 都成功
# 之後，把整個 /srv/init 砍掉（連自己這支也一起砍——rm -rf 當下這支
# 腳本自己還在跑，Linux 允許刪除一個正在執行中的檔案，跟原本單支
# bootstrap-firewall.sh.j2 自己 `rm -f "$0"` 自刪是同一個原理，只是現在
# 刪的是整個目錄）。
#
# 故意拆成獨立這一支，不是直接放在前面任何一支腳本的最後一步：每一支
# 腳本自己的成功/失敗語意應該只反映它自己那件事有沒有做成功，混進一個
# 跟它無關的 rm 操作會讓那支腳本的失敗原因變得含糊。這支靠
# finalizer.service 的 After=/Requires=software-install.service 保證
# 只有在 software-install.service 真的 active 之後才會被排進去跑——而
# software-install.service 自己又 Requires firewall.service、
# firewall.service 又 Requires podman-network.service，一路往前串，
# 所以只要排到這支會跑，代表前面三支全部都已經成功。其中任何一支失敗，
# 這支根本不會被觸發，/srv/init 原樣留著，可以修完問題再重跑。
#
# 刪掉之後，四個 service 的 ConditionPathExists 全部永久不成立，不會在
# 下次開機被 systemd 再跑一次。

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 sudo 執行這支程式（例如：sudo /srv/init/finalizer.sh）" >&2
  exit 1
fi

rm -rf /srv/init
