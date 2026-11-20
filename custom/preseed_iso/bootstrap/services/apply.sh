#!/bin/bash
set -euo pipefail

# bootstrap-services（Go 表單）把使用者填的答案用 JSON 丟到這支腳本的 stdin。
# 這支只負責最上層的流程編排：裝好 ansible-navigator、建
# EE image、依序處理 harbor.sh（Harbor 的安裝/CA/登入/mirror 設定）跟
# nginx.sh（裝 nginx-proxy），最後印結果。每個服務自己的細節都拆到各自的
# .sh，這支不重複寫那些邏輯——好處是以後要新增別的服務，一樣是「寫一支
# 新的 xxx.sh + 在這裡多呼叫一行」，不用動既有服務的程式碼。
#
# harbor.sh 是用 source 讀進來、再明確呼叫 harbor_setup 這個函式——不是當
# 子行程執行。跟 config.sh 的慣例一致：source 只負責載入定義，不會有副
# 作用，真正執行要靠呼叫端自己叫函式。這支需要 harbor_setup 算出來的
# harbor_registry 這個值，用函式讓它直接變成這支腳本自己的變數，不需要靠
# $(...) 接 stdout（那樣 harbor.sh 裡任何一行 echo 忘記送 stderr 都會污染
# 這個值）。nginx.sh 不需要回傳任何東西，維持子行程執行就好。
#
# 失敗就直接 exit（set -e 會讓任何一步失敗時整支腳本中止），不會自己清理
# 任何東西——bootstrap-services（Go）看到這支腳本失敗，不會刪除這組檔案，
# 讓使用者修完問題後可以直接重跑這支腳本（重跑時 stdin 要再給一次同樣的
# JSON——錯誤訊息裡會提示）。一次性：跑完成功，由 bootstrap-services 負責
# 把整個 services/ 資料夾跟自己一起刪掉，這裡完全不管自我刪除的事。沒有另外
# 用標記檔案判斷「跑過沒有」——自我刪除本身就是紀錄，東西都不在了就代表
# 跑完了，不需要額外的檔案來擋重跑。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 root 執行這支程式" >&2
  exit 1
fi

answers=$(cat)
export INSTALL_HARBOR
export HARBOR_HOSTNAME
export HARBOR_URL
export HARBOR_USERNAME
export HARBOR_PASSWORD
export WIREGUARD_VM_ADDRESS
INSTALL_HARBOR=$(jq -r '.install_harbor' <<<"$answers")
HARBOR_HOSTNAME=$(jq -r '.harbor_hostname' <<<"$answers")
HARBOR_URL=$(jq -r '.harbor_url' <<<"$answers")
HARBOR_USERNAME=$(jq -r '.harbor_username' <<<"$answers")
HARBOR_PASSWORD=$(jq -r '.harbor_password' <<<"$answers")
WIREGUARD_VM_ADDRESS=$(jq -r '.wireguard_vm_address' <<<"$answers")

"$SCRIPT_DIR/software-install.sh"

# squid.sh 要排在 ensure_ee_image 之前——EE image build 需要先有 squid
# 正向代理才連得出去（full bump，見該腳本自己的說明）。squid.sh 不需要
# 表單欄位，直接執行即可，不像 harbor.sh 需要 source 進來呼叫函式。
"$SCRIPT_DIR/squid.sh"

ensure_navigator_tools
ensure_ee_image

# ansible-navigator.yml 的 volume-mounts 是一份共用設定，同時列了
# /home/harbor 跟 /home/nginx-proxy——不管接下來實際跑的是
# harbor-install.yml 還是 nginx-proxy-install.yml，ansible-navigator 自己
# 在容器啟動前都會檢查這份清單裡*全部*的來源路徑存在，不只是當次用到的
# 那一個（實機撞過 "Source: '/home/nginx-proxy' does not exist"，發生在
# 跑 harbor-install.yml 的時候，因為 /home/nginx-proxy 要等 nginx.sh 才會
# 建）。這裡集中建好兩個目錄，不要分散到 harbor.sh/nginx.sh 各自只顧自己
# 那一個：harbor.sh 原本的 mkdir 包在 INSTALL_HARBOR=true 分支裡，使用者
# 選接外部既有 Harbor 的話根本不會執行到，等 nginx.sh 呼叫 run_navigator
# 時一樣會死在 /home/harbor 不存在——這個集中寫法兩種情境都會先建好，不用
# 看 INSTALL_HARBOR 的值。harbor/nginx-proxy 是 control-panel/debian.yml
# 寫死的 rootless 使用者名稱常數，跟 ansible-navigator.yml 裡的掛載路徑
# 一致，這裡直接寫字串、不透過樣板傳。
mkdir -p /home/harbor /home/nginx-proxy

# 先宣告成空字串，純粹是給人看的文件（標示「這支腳本最後會用到這個變數」），
# 不影響行為——harbor_setup 執行完之後會直接覆寫成真正的值，沒有加這行
# 一樣會動，見前面測試過的「source/函式賦值不會因為重複宣告而衝突」。
harbor_registry=""

echo "==> 處理 Harbor（本機安裝或接外部既有的）..."
# shellcheck source=harbor.sh
source "$SCRIPT_DIR/harbor.sh"
harbor_setup

"$SCRIPT_DIR/nginx.sh"

echo ""
echo "全部裝完了："
if [ "$INSTALL_HARBOR" = "true" ]; then
  echo "  Harbor：https://${harbor_registry}"
else
  echo "  已接上外部 Harbor：${harbor_registry}"
fi
echo "  nginx-proxy：https://${WIREGUARD_VM_ADDRESS}:${NGINX_PROXY_HTTPS_PORT}"
