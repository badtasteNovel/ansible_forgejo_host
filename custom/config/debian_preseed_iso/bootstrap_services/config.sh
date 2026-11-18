# 共用的環境設定——apply.sh/harbor.sh/nginx.sh 都在自己最前面 source 這份，
# 不要各自宣告一樣的路徑常數、各自檢查一次 ansible-builder/ansible-navigator
# 在不在。這份檔案本身不是可執行腳本（沒有 shebang、沒有 set -e），純粹是
# source 進別人 shell 的設定/函式庫，被 source 進來的腳本自己的 set -euo pipefail
# 照樣生效。
#
# PATH 加上 pipx 安裝位置（/root/.local/bin），這樣下面的程式碼可以直接寫
# ansible-navigator/ansible-builder（裸指令名稱），不用每個地方都寫一次完整
# 路徑——這整組腳本全程以 root 身份跑（apply.sh 一開始就檢查過 euid），pipx
# 裝的東西固定在 /root/.local/bin。
export PATH="/root/.local/bin:$PATH"

PROXY_MAP_PATH=/opt/bootstrap/harbor/proxy_map.json
# 整台 VM 唯一對外開放的埠（單一埠 + hostname 分流，不是一個服務一個埠）
# ——寫死常數，不是裝機前渲染進來的值：control-panel/debian.yml 自己也是
# 寫死 443，從來不是每台 VM 不一樣的東西，跟下面這些路徑常數待遇一樣，
# 不需要另外搞一份注入檔案來傳這一個數字。
NGINX_PROXY_HTTPS_PORT=443
EE_DIR=/opt/bootstrap/ansible-ee
EE_IMAGE=localhost/vm-ansible-ee:latest
HARBOR_PLAYBOOK=/opt/bootstrap/harbor/harbor-install.yml
NGINX_PROXY_PLAYBOOK=/opt/bootstrap/nginx/nginx-proxy-install.yml
HARBOR_SECRETS_DIR=/opt/harbor/secrets
LOCAL_HARBOR_CA_PATH=/opt/bootstrap/nginx/certs/ca.crt # 本機裝 Harbor 時，nginx-proxy 的 CA（control-panel/debian.yml 裝機前就簽好、隨 ISO 注入）
LOCAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-local-harbor-ca.crt
EXTERNAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-external-harbor-ca.crt
MIRROR_AUTH_FILE=/etc/containers/mirror-auth.json # 所有 rootless 使用者共用這一份登入憑證檔，見 custom/scripts/tasks/ansible/rootless_podman_user/setup.yml
MIRROR_CONF_PATH=/etc/containers/registries.conf.d/harbor-mirror.conf

# 確認 ansible-builder/ansible-navigator 可用——不負責安裝，這兩個工具是
# late_command 裝機當下就用 pipx 裝好的（見 preseed.cfg.j2 開頭那兩行
# in-target pipx install），golden image 一出來就該有，這裡沒找到就是
# golden image 建置有問題，直接報錯、不嘗試現場補裝。
ensure_navigator_tools() {
  if command -v ansible-navigator >/dev/null 2>&1 && command -v ansible-builder >/dev/null 2>&1; then
    return 0
  fi
  echo "錯誤：找不到 ansible-builder/ansible-navigator——golden image 應該在裝機當下就用 pipx 裝好了（見 preseed.cfg.j2 的 late_command），這裡找不到代表 image 建置有問題" >&2
  exit 1
}

# 建 Execution Environment image——這次的 image pull 不透過 Harbor 快取
# （Harbor 這時可能還沒裝、或根本不存在，先有雞才有蛋的必要例外）。
ensure_ee_image() {
  if podman image exists "$EE_IMAGE"; then
    return 0
  fi
  echo "==> 建立 Execution Environment image（ansible-builder build，第一次會花比較久）..." >&2
  ansible-builder build -f "$EE_DIR/execution-environment.yml" -c "$EE_DIR/build-context" -t "$EE_IMAGE"
}

# 用環境變數指定設定檔位置（ANSIBLE_NAVIGATOR_CONFIG），不是靠 ansible-navigator
# 自動從目前工作目錄找 ansible-navigator.yml——這組腳本有可能從任何目錄被
# 呼叫，不應該依賴呼叫當下的 cwd 剛好是 EE_DIR。-m stdout 再帶一次，跟設定
# 檔裡的 mode: stdout 重複沒關係，只是多一層保險。
run_navigator() {
  ANSIBLE_NAVIGATOR_CONFIG="$EE_DIR/ansible-navigator.yml" ansible-navigator run "$1" -m stdout
}
