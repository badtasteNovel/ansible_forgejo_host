# 共用的環境設定——apply.sh/harbor.sh/nginx.sh/software-install.sh、
# /srv/harbor/rotate/update.sh 這種日常維運腳本都在自己最前面 source 這份，不要
# 各自宣告一樣的路徑常數。這份檔案本身不是可執行腳本（沒有 shebang、沒有
# set -e），純粹是 source 進別人 shell 的設定/函式庫，被 source 進來的腳本
# 自己的 set -euo pipefail 照樣生效。
#
# ansible-navigator/Execution Environment 共用的那塊（PATH、ensure_navigator_tools/
# ensure_ee_image/run_navigator）直接寫在這支裡面，不拆成另一支 shell script
# ——這些工具相關的「值」（EE_DIR/EE_IMAGE）才拆成 /srv/ansible/ee.conf 這個
# 純資料的 .conf 檔，這支負責讀它；任何地方要用 ansible-navigator，一律只
# source 這一份 config.sh 就夠，不用另外多 source 別的東西。
source /srv/ansible/ee.conf

# PATH 加上 pipx 安裝位置（/root/.local/bin），這樣下面可以直接寫
# ansible-navigator/ansible-builder（裸指令名稱）——這些工具全程以 root
# 身份跑，pipx 裝的東西固定在 /root/.local/bin。
export PATH="/root/.local/bin:$PATH"

# 確認 ansible-builder/ansible-navigator 可用——不負責安裝。這兩個工具理論上
# late_command 裝機當下就該用 pipx 裝好了（見 preseed.cfg.j2），實際裝不裝
# 得成功則是由 bootstrap_services/software-install.sh 在開機後第一次執行時
# 補一層保證；這支只檢查，缺了就直接報錯、不嘗試現場補裝。
ensure_navigator_tools() {
  if command -v ansible-navigator >/dev/null 2>&1 && command -v ansible-builder >/dev/null 2>&1; then
    return 0
  fi
  echo "錯誤：找不到 ansible-builder/ansible-navigator" >&2
  exit 1
}

# 建 Execution Environment image——這次的 image pull 不透過 Harbor 快取
# （Harbor 這時可能還沒裝、或根本不存在，先有雞才有蛋的必要例外）。
ensure_ee_image() {
  if podman image exists "$EE_IMAGE"; then
    return 0
  fi
  echo "==> 建立 Execution Environment image（ansible-builder build，第一次會花比較久）..." >&2
  # --container-runtime podman：明確指定，不吃 ansible-builder 自己的預設值
  # （目前預設恰好也是 podman，但這是它的事，不是這個專案自己宣告的值，不
  # 明確寫出來的話，往後 ansible-builder 哪個版本換了預設、或這台機器哪天
  # 也裝了 docker，實際用哪個引擎會悄悄變掉）。
  # --extra-build-cli-args 傳給實際執行的 podman build：--network 指到
  # /srv/init/podman-network.sh 建好的那個專用 network；--volume 把
  # bootstrap/services/squid.sh 產生的 CA 憑證（只有憑證，不含私鑰）
  # bind-mount 進 build container 固定路徑 /tmp/squidCA.crt——Containerfile
  # 的 COPY 只能從 build context 讀，CA 憑證放在宿主機
  # /etc/squid/ssl_cert/，不在 context 裡，所以用這個 podman/buildah build
  # 特有的擴充語法（不是 Docker BuildKit 的 RUN --mount），execution-
  # environment.yml 裡對應的 RUN 步驟會把它放進信任鏈。不再需要 --dns：
  # build container 不直接解析任何外部網域，只需要連到 10.90.0.1 這個
  # 固定 IP（squid 自己監聽的 gateway 位址），不涉及 DNS。
  #
  # http_proxy/https_proxy 故意只用行內賦值（command-scoped），不是
  # export——squid 的白名單只開給這個 build 用到的那幾個網域，export 出去
  # 的話會污染 apply.sh 呼叫這支函式之後的其他步驟（harbor.sh 的
  # podman login、curl getcert 之類），讓那些完全不相關的連線也被迫走這個
  # proxy、被白名單擋掉。這兩個變數是給 podman build 自己的 --http-proxy
  # （預設 true）機制用的：podman build 看到呼叫它的行程環境裡有這兩個
  # 變數，會自動原封不動帶進每一個 RUN 步驟的環境，不需要另外用
  # --build-arg 傳。
  http_proxy="http://10.90.0.1:3128" \
  https_proxy="http://10.90.0.1:3128" \
  no_proxy="" \
    ansible-builder build --container-runtime podman \
    --extra-build-cli-args '--network ansible-builder-network --volume /etc/squid/ssl_cert/squidCA.crt:/tmp/squidCA.crt:ro' \
    -f "$EE_DIR/execution-environment.yml" -c "$EE_DIR/build-context" -t "$EE_IMAGE"
}

# 用環境變數指定設定檔位置（ANSIBLE_NAVIGATOR_CONFIG），不是靠 ansible-navigator
# 自動從目前工作目錄找 ansible-navigator.yml——呼叫這個函式的腳本有可能從
# 任何目錄被呼叫，不應該依賴呼叫當下的 cwd 剛好是 EE_DIR。-m stdout 再帶
# 一次，跟設定檔裡的 mode: stdout 重複沒關係，只是多一層保險。
run_navigator() {
  ANSIBLE_NAVIGATOR_CONFIG="$EE_DIR/ansible-navigator.yml" ansible-navigator run "$1" -m stdout "${@:2}"
}

PROXY_MAP_PATH=/srv/harbor/proxy_map.json
# 整台 VM 唯一對外開放的埠（單一埠 + hostname 分流，不是一個服務一個埠）
# ——寫死常數，不是裝機前渲染進來的值：control-panel/debian.yml 自己也是
# 寫死 443，從來不是每台 VM 不一樣的東西，跟下面這些路徑常數待遇一樣，
# 不需要另外搞一份注入檔案來傳這一個數字。
NGINX_PROXY_HTTPS_PORT=443
HARBOR_PLAYBOOK=/srv/ansible/playbook/harbor-install.yml
NGINX_PROXY_PLAYBOOK=/srv/ansible/playbook/nginx-proxy-install.yml
HARBOR_SECRETS_DIR=/srv/harbor/secrets
LOCAL_HARBOR_CA_PATH=/srv/nginx/certs/ca.crt # 本機裝 Harbor 時，nginx-proxy 的 CA（control-panel/debian.yml 裝機前就簽好、隨 ISO 注入）
LOCAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-local-harbor-ca.crt
EXTERNAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-external-harbor-ca.crt
MIRROR_AUTH_FILE=/etc/containers/mirror-auth.json # 所有 rootless 使用者共用這一份登入憑證檔，見 custom/preseed_iso/srv/ansible/playbook/rootless_podman_user_setup.yml
MIRROR_CONF_PATH=/etc/containers/registries.conf.d/harbor-mirror.conf
