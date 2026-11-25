# 共用的環境設定——apply.sh/harbor.sh/caddy.sh、
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

# 確認 ansible-navigator 可用——不負責安裝。這個工具不是在 late_command
# 裝的（pipx install 需要真實網路/完整使用者環境，late_command 的 d-i
# chroot 不保證——實機撞過，VM 開機後完全找不到這個指令），是 VM 真正
# 開機後由 /srv/init/software-install.sh 透過自己的 systemd unit
# 自動裝好（見該腳本自己的說明）；這支只檢查，缺了就直接報錯、不嘗試
# 現場補裝。裝的目的地是系統全域的 /usr/local/bin（pipx install
# --global），不是哪個使用者自己的 ~/.local/bin，不需要額外加 PATH——
# systemd service／互動式 shell 的預設 PATH 本來就含 /usr/local/bin。
ensure_navigator_tools() {
  if command -v ansible-navigator >/dev/null 2>&1; then
    return 0
  fi
  echo "錯誤：找不到 ansible-navigator" >&2
  exit 1
}

# 建 Execution Environment image——這次的 image pull 不透過 Harbor 快取
# （Harbor 這時可能還沒裝、或根本不存在，先有雞才有蛋的必要例外）。
#
# 不透過 ansible-builder 產生 Containerfile，是直接用 Containerfile（跟
# 這支同目錄）自己手寫、自己 podman build——ansible-builder 官方明確只
# 支援 RPM 系 base image（dnf/microdnf），Debian/Ubuntu 的 apt-get 不
# 支援、會直接 build 失敗（查過官方文件跟 GitHub issue #636，maintainer
# 原話："intentionally designed to work only with RHEL'ish images"，不是
# 設定錯誤，是這個工具本身的硬性限制）。舊版用 quay.io/ansible/creator-ee
# （Fedora 系）當 base image，撞到過一個實質的相容性問題：
# ansible-navigator.yml 把宿主機（Debian）整個 /etc 掛進容器，Debian
# 風格的 /etc/pam.d 蓋掉了容器自己原生的 Fedora PAM 設定，兩者不相容，
# 導致 sudo 的 PAM account 階段永遠拒絕（跟哪個帳號完全無關，連
# `sudo -n -u root id` 切給自己都失敗；拿掉整個 /etc 掛載、只用容器原生
# 環境測同一行指令，PAM 直接成功，兩邊對照確定是設定檔格式不相容，不是
# 帳號/密碼設定的問題）。改成手寫 Containerfile、base image 直接用
# debian:13-slim 之後，宿主機跟容器是同一個發行版，/etc 整個掛進去不會
# 再有這類跨發行版設定檔衝突，問題在根源上消失，不需要像之前那樣另外
# 存一份 image 原生 /etc/pam.d 蓋回去的繞路修法。quay.io/ansible/
# creator-ee 本身也已經封存不再維護（官方建議改用
# ghcr.io/ansible/community-ansible-dev-tools，但那個一樣是 Fedora 系，
# 換了也解決不了相容性問題，所以沒有採用），這個改動同時解決了「依賴一個
# 死專案」的問題。
ensure_ee_image() {
  if podman image exists "$EE_IMAGE"; then
    return 0
  fi
  echo "==> 建立 Execution Environment image（手寫 Containerfile，第一次會花比較久）..." >&2

  # base image（debian:13-slim）先在這裡拉好，不交給下面 podman build
  # 自己的 FROM 那一步去拉：這個專案的目標是「所有對外連線都要經過 squid
  # 稽核」，宿主機自己的 podman pull 不應該例外直接打外網。這裡用
  # https_proxy=http://127.0.0.1:3128 經過 squid.sh 裝好、也讓宿主機信任
  # 其 CA 的那個 squid（squid 監聽所有介面，天生就包含 127.0.0.1，不需要
  # 額外設定；squid.conf 的 acl localnet 已經多認了這個來源）。用
  # 127.0.0.1，不是 10.90.0.1：這裡是宿主機自己發起的連線，直接走
  # loopback 就好，10.90.0.1 是給 build container 連回宿主機用的 bridge
  # gateway，宿主機不需要、也不應該繞那條路連自己。docker.io 相關網域
  # 要先在 squid.sh 的白名單裡（見該腳本的說明）否則這裡會被 squid 自己
  # 的白名單擋下來。拉好之後，下面 podman build 的 FROM 那一步看到本機
  # 已經有這個 image，就不會再發起任何網路存取。
  if ! podman image exists debian:13-slim; then
    https_proxy="http://127.0.0.1:3128" podman pull debian:13-slim
  fi

  # --network 指到 /srv/init/podman-network.sh 建好的那個專用 network；
  # --build-arg 把 proxy 位址傳給 RUN 步驟（Containerfile 裡的 apt-get/
  # pip 都要經過 squid）。http_proxy/https_proxy 故意用 --build-arg 傳，
  # 不是 export 成這支函式呼叫 podman build 的外層環境變數——外層環境
  # 變數會被 podman/skopeo 自己（不只是 RUN 步驟，連 FROM 的 registry
  # 存取都會讀到，Go 的 net/http 標準行為，不是 podman build 的
  # --http-proxy 選項控制的範圍）直接讀到；base image 已經在上面拉好、
  # FROM 這一步不會再碰網路，理論上用哪種傳法對 FROM 都沒差，但維持跟
  # 「外層行程的環境變數會被非預期的地方讀到」這個已經撞過一次的坑保持
  # 距離，不要在這裡重新引入同一種風險。--build-arg 傳的值只會透過
  # Containerfile 內部的 ARG/ENV 機制給 RUN 步驟（http_proxy/https_proxy
  # 屬於 Docker/buildah 內建的「predefined build args」清單，RUN 步驟
  # 不用在 Containerfile 裡額外寫 ARG 宣告就會自動拿到）。
  #
  # build context 給 /etc/squid/ssl_cert/（squid.sh 產生 CA 的那個目錄）
  # ，不是 $EE_DIR——Containerfile 裡的 COPY squidCA.crt 只能從 context
  # 讀，CA 憑證放在宿主機這個路徑，不在 $EE_DIR 底下。這個目錄裡還有
  # squidCA.key/squidCA.pem，COPY 只取 squidCA.crt 這一個檔案，其餘的
  # 檔案只是也一起被當成 context 送進 podman build（純本機操作，沒有
  # 遠端 daemon，不會被送到任何地方），不是風險。
  podman build \
    --network ansible-builder-network \
    --build-arg http_proxy=http://10.90.0.1:3128 \
    --build-arg https_proxy=http://10.90.0.1:3128 \
    -f "$EE_DIR/Containerfile" -t "$EE_IMAGE" /etc/squid/ssl_cert
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
CADDY_PROXY_HTTPS_PORT=443
HARBOR_PLAYBOOK=/srv/ansible/playbook/harbor-install.yml
CADDY_PROXY_PLAYBOOK=/srv/ansible/playbook/caddy-proxy-install.yml
HARBOR_SECRETS_DIR=/srv/harbor/secrets
LOCAL_HARBOR_CA_PATH=/srv/caddy/data/pki/authorities/local/root.crt # 本機裝 Harbor 時，caddy-proxy 的 CA——這不是裝機前簽好注入的東西，是 Caddy 自己用 tls internal 第一次處理 site 時才現場生成、寫進掛進去的 /data（見 caddy-proxy-install.yml），harbor.sh 要在 caddy-proxy-install.yml 跑完之後才會讀到這個檔案。路徑底下沒有多一層 caddy/——Caddyfile 的 `storage file_system /data` 就是直接指定 /data 本身當 storage 根目錄，不會再多一層；/data/caddy/ 這個目錄確實存在，但裡面只有 instance.uuid，跟這張 CA 無關，不要被名字騙了（caddy-proxy-install.yml 原本也多寫了這層，兩邊是同一個錯，一起修）
LOCAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-local-harbor-ca.crt
EXTERNAL_CA_TRUST_PATH=/usr/local/share/ca-certificates/bootstrap-services-external-harbor-ca.crt
MIRROR_AUTH_FILE=/etc/containers/mirror-auth.json # 所有 rootless 使用者共用這一份登入憑證檔，見 custom/preseed_iso/srv/ansible/playbook/rootless_podman_user_setup.yml
MIRROR_CONF_PATH=/etc/containers/registries.conf.d/harbor-mirror.conf
