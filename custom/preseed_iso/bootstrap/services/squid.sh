#!/bin/bash
set -euo pipefail

# 設定 squid（套件安裝見 preseed.cfg.j2 的 pkgsel/include，這支只負責產生
# CA、寫設定、啟用服務），當 EE image 建置（手寫 Containerfile → podman
# build，見 config.sh 的 ensure_ee_image()）專用的正向代理——full bump
# 模式：對每個 CONNECT 一律解密、用自己的 CA 重簽，http_access 比對到的
# 是解密後真正的 Host，不是 client 自稱的 CONNECT 目標或 TLS SNI（這兩者
# 都可能跟封包裡實際的 Host 不一致，是只做 peek+splice 會留下的洞，討論
# 過後決定接受 full bump 多出來的成本——多一張 CA 要塞進 build container
# 的信任鏈，見 Containerfile 跟 config.sh）。
#
# apply.sh 呼叫這支的時機要排在 ensure_ee_image 之前（squid 沒先跑起來，
# EE build 連不出去）；跟 harbor.sh/caddy.sh 不一樣，這支不需要表單填的
# 任何欄位，所以不用被 source 進去定義函式讓 apply.sh 呼叫——直接執行
# 就好。
#
# 放在 bootstrap/services/（跟著互動式的 bootstrap-services 表單跑一次），
# 不是放進 srv/init/（開機就自動跑、不需要人介入）：squid 唯一的消費者
# ensure_ee_image() 本身就只會從 apply.sh 這條互動流程被呼叫到，沒有任何
# 地方在開機當下自動建 EE image，所以 squid 沒有必要比 bootstrap-services
# 更早就位——跟 harbor.sh/caddy.sh 同一個道理，簡單起見直接沿用一次性表單
# 流程的既有慣例就好。這也代表 podman-network.sh（srv/init/，開機就自動
# 跑）這時早就跑完了，ansible-builder-network 這個 network 的*設定*
# 已經存在——但這支腳本不需要在乎這個 network 的 gateway IP
# （10.90.0.1）這時有沒有真的掛在某個介面上：下面 http_port 刻意不指定
# 位址（監聽所有介面），不去綁那個位址。
#
# 曾經讓 http_port 綁死在 10.90.0.1，想法是當 ufw/acl localnet 來源限制
# 之外「多一層防護」，結果撞上真正的麻煩：podman（netavark 後端）只在
# 「第一個掛在這個 network 上的 container 真正啟動」才會建出實際的
# bridge/gateway IP（`podman network create` 當下只寫設定檔），而這台
# VM 第一個這麼做的是 ensure_ee_image() 的 podman build——比
# squid.sh 執行的時間點晚，所以綁定那個位址會在它還不存在時 bind 失敗
# （實機撞過）。想解決這個時間差，試過 warmup pod、靜態 bridge、全域
# net.ipv4.ip_nonlocal_bind sysctl 三個方向，都有各自的代價，最後發現
# 問題根本不需要解決：10.90.0.1 是 podman 內部用來讓 container 連回
# host 的位址，是 podman 自己的路由機制，不是這支腳本或 OS 本身需要去
# 特別認的東西——squid 完全不需要知道、也不需要綁定這個位址，只要監聽
# 所有介面，讓 build container 的封包（目的地自然就是它自己的 gateway
# 10.90.0.1）送達就好。真正的存取控制已經有兩層獨立機制在做，跟 squid
# 綁在哪個位址完全無關：
# - ufw 的 INPUT 規則（見 firewall.sh.j2）比對封包的目的地位址/port，
#   跟 squid 自己綁在哪個介面上無關；
# - 下面 squid.conf 自己的 `acl localnet src 10.90.0.0/24` +
#   `http_access deny !localnet`，直接比對封包的來源位址。
# 綁定特定位址這件事，從頭到尾都沒有對這兩層多加任何實質防護，純粹是
# 讓 squid 的啟動多了一個跟 podman 內部生命週期耦合的脆弱依賴，拿掉。

if [ "$(id -u)" -ne 0 ]; then
  echo "錯誤：請用 root 執行這支程式" >&2
  exit 1
fi

# squid 套件本身不在這支腳本裡裝——跟 ufw/wireguard-tools/chrony 一樣，
# 已經在 preseed.cfg.j2 的 d-i pkgsel/include 清單裡，golden image 裝機
# 當下就裝好了（d-i 的 pkgsel 走的是正常的套件安裝流程，比 late_command
# 在 d-i chroot 裡現場呼叫 apt-get 可靠——這支專案已經在 ufw 身上撞過
# late_command 現場操作在 chroot 裡悄悄失效的狀況，見 firewall.sh.j2 的
# 說明，所以能用 pkgsel 裝好的套件就不要留給執行階段再裝）。這支只檢查、
# 缺了就直接報錯，不嘗試現場補裝——跟 config.sh 的 ensure_navigator_tools()
# 同一個分工方式。
#
# pkgsel 裝的是 squid-openssl，不是 squid 本身——Debian/Ubuntu 官方預設的
# squid 套件編譯成連 GnuTLS（授權問題，Squid 的授權跟早期 OpenSSL 授權
# 條款混用有爭議），下面 squid.conf 用的 ssl-bump（cert=/key=、ssl_bump
# 那些指令）依賴 OpenSSL 專屬的 API，一般 squid 套件根本不支援，會在
# squid -k parse 這一步直接報錯。squid-openssl 跟 squid 是互斥的替代套件
# （provides/conflicts 同一組檔案，兩者不能同時裝），但裝出來的執行檔
# 一樣叫 squid，所以這裡的 command -v squid 檢查不用跟著改。
if ! command -v squid >/dev/null 2>&1; then
  echo "錯誤：找不到 squid——應該已經在 preseed.cfg.j2 的 pkgsel/include 裝好了（squid-openssl 套件），golden image 建置流程有問題" >&2
  exit 1
fi

SSL_CERT_DIR=/etc/squid/ssl_cert
# squid 動態簽發憑證用的快取資料庫，只有幾 MB（下面 -M 4MB 就是上限），
# 跟 Harbor 掛的那顆獨立硬碟（/dev/sdc，存的是真正的 image blob，會長到
# GB 等級）完全不是同一個量級，不需要、也不應該為它另外切一顆硬碟——跟
# 系統其他小型快取/狀態檔案一樣，放在根目錄的 /var/lib 底下就好。
SSL_DB_DIR=/var/lib/squid/ssl_db

mkdir -p "$SSL_CERT_DIR"

# CA 只在第一次跑的時候產生——重跑這支腳本（例如上次失敗要重試）不應該
# 換掉已經存在的 CA：換了的話，動態簽發憑證資料庫（下面的 SSL_DB_DIR）
# 之前簽出去的憑證全部作廢，而且如果 EE image 已經 build 過一次、把舊的
# CA 信任進去了，兩邊的 CA 會對不起來。
if [ ! -f "$SSL_CERT_DIR/squidCA.pem" ]; then
  echo "==> 產生 squid 的 CA（只給這台 VM 自己的 EE build container 信任，不是公開 CA，只用在 full bump 重簽）..."
  # -addext 這兩條：實機撞過 harbor-install.yml 查 GitHub release 的
  # ansible.builtin.uri task 噴 "[SSL: CERTIFICATE_VERIFY_FAILED]
  # certificate verify failed: CA cert does not include key usage
  # extension"——這台機器裝的 openssl 版本，`openssl req -x509` 不帶
  # -addext 時只會自動補上 Basic Constraints（CA:TRUE），不會自動補
  # Key Usage，產生出來的 CA 證書完全沒有這個 extension（直接用
  # openssl x509 -text 確認過）。大部分用 openssl/curl 驗證的消費者
  # （podman/skopeo 拉 debian:13-slim 那個 pull、squid 自己簽發葉證書）
  # 對缺這個 extension 比較寬容，但 Python 的 ssl 模組（ansible.builtin.
  # uri/get_url 底層用的就是這個）驗證 CA 簽署資格時要求明確看到
  # keyCertSign 這個 bit，缺了就直接判定整條證書鏈不可信，不是這個
  # GitHub API 呼叫本身有問題。之前這個呼叫沒撞過這個 bug，純粹因為它
  # 從來沒經過 squid（EE 容器原本用 --network=host 直接打外網，繞過
  # squid 的稽核），這輪改成走 http_proxy/https_proxy 經過 squid 之後，
  # 才第一次真的用嚴格驗證的用戶端去檢查這張自簽 CA。
  openssl req -new -newkey rsa:4096 -sha256 -days 3650 -nodes -x509 \
    -keyout "$SSL_CERT_DIR/squidCA.key" \
    -out "$SSL_CERT_DIR/squidCA.crt" \
    -subj "/CN=debian-vm squid full-bump CA (EE build only)" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  cat "$SSL_CERT_DIR/squidCA.key" "$SSL_CERT_DIR/squidCA.crt" >"$SSL_CERT_DIR/squidCA.pem"
fi
# proxy 不是這支腳本自己建的使用者——它是 Debian 的 base-passwd 套件在
# 每一台機器上都會保留的標準系統帳號之一（UID/GID 13，從早期 Debian 就
# 保留給 proxy 類服務用，跟 www-data/backup/list 這些系統帳號是同一批，
# base-passwd 是 Priority: required，再精簡的安裝也會有），squid 套件
# 自己預設就是以這個帳號跑（squid.conf 沒特別寫 cache_effective_user 的
# 話，套件內建的預設值就是 proxy）。這裡只是把目錄的擁有者對齊成跟 squid
# 執行時的身份一致，不是在生造一個新帳號。
chown -R proxy:proxy "$SSL_CERT_DIR"
chmod 640 "$SSL_CERT_DIR/squidCA.key" "$SSL_CERT_DIR/squidCA.pem"
# squidCA.crt（憑證本身，不含私鑰）故意維持世界可讀——config.sh 的
# ensure_ee_image() 會把它 bind-mount 進 build container 給 RUN 步驟讀，
# 不想因為擁有者是 proxy 而讀不到。
chmod 644 "$SSL_CERT_DIR/squidCA.crt"

# 讓宿主機自己也信任這張 CA——config.sh 的 ensure_ee_image() 現在會先在
# 宿主機上用 https_proxy=http://127.0.0.1:3128 經過這個 squid 把 EE
# image 的 base image（debian:13-slim）拉下來，不讓宿主機自己的
# podman pull 繞過 squid 直接打外網（跟 build container 裡 RUN 步驟的
# 套件安裝一樣，全部對外連線都要經過這裡稽核/比對白名單）。
# full bump 會用這張 CA 重簽宿主機看到的憑證，宿主機自己的 TLS client
# （podman/skopeo，底層是 Go 的 crypto/x509，在 Debian 上吃的是
# update-ca-certificates 維護的那份系統信任鏈）不信任的話，pull 會直接
# 卡在憑證驗證失敗——跟 harbor.sh 信任 Harbor CA 是同一個道理
# （LOCAL_CA_TRUST_PATH），只是這次信任的是這支腳本自己剛生出來的 CA。
cp "$SSL_CERT_DIR/squidCA.crt" /usr/local/share/ca-certificates/ansible-builder-network-squid-ca.crt
update-ca-certificates

# 動態簽發憑證用的資料庫——squid 第一次啟動前沒初始化過的話，ssl-bump 會
# 直接失敗。這個目錄本身不是設定檔，是 security_file_certgen 自己管理的
# 資料庫檔案，初始化過一次之後就一直沿用，不需要每次重跑這支腳本都重建。
#
# security_file_certgen -c 只會建 ssl_db 這一層（leaf 目錄），不會連父目錄
# /var/lib/squid 一起建——squid-openssl 套件本身不保證裝完就有這個父目錄
# （實機撞過 "Cannot create /var/lib/squid/ssl_db"，父目錄不存在，mkdir
# 單層目錄當然失敗），所以這裡先手動確保父目錄存在。
if [ ! -d "$SSL_DB_DIR" ]; then
  echo "==> 初始化 squid 的動態憑證資料庫..."
  mkdir -p "$(dirname "$SSL_DB_DIR")"
  /usr/lib/squid/security_file_certgen -c -s "$SSL_DB_DIR" -M 4MB
  chown -R proxy:proxy "$SSL_DB_DIR"
fi

# 白名單網域清單——故意拆成獨立檔案，不是寫死在 squid.conf 裡：以後任何
# 網域要放進白名單，直接編輯這個檔案（一行一個網域，開頭加 . 代表含子
# 網域）就好，不用碰 squid.conf、也不用重新理解整份設定。只在第一次建立
# 時寫入 seed 內容，重跑這支腳本不會蓋掉之後手動加上去的網域。
#
# 目前的 seed 內容對應 Containerfile 跟 ensure_ee_image() 實際會連到的
# 網域：.docker.io/.docker.com 是拉 base image（debian:13-slim，Docker
# Hub）要用的——registry-1.docker.io/auth.docker.io 這些 API 本身是
# docker.io 底下的子網域，實際的 image layer 內容多半是從 Cloudflare 的
# CDN（production.cloudflare.docker.com，docker.com 底下）送出來的，兩個
# 頂層網域一起開才夠；.debian.org 是 Containerfile 裡 apt-get 要用的；
# .pypi.org/.files.pythonhosted.org 是 pip install ansible-core 要用的；
# .github.com/.githubusercontent.com 是 Containerfile 下載 yq（Mike Farah
# 寫的 Go 版，不是 Debian 套件庫裡那個 Python 包 jq 的舊版 yq，兩者指令語法
# 完全不相容，harbor-install.yml 用的 `del(...)`/`.services[].x = {...}`
# 這種語法只有 Go 版才支援）二進位檔要用的——GitHub release 的實際檔案是從
# objects.githubusercontent.com 這個 CDN 網域送出來的，跟 release 頁面本身
# 的 github.com 是兩個不同網域，要一起開。
# 這幾個都不是猜的，是對著 Containerfile 實際的 FROM/RUN 內容推出來的，
# 但沒有實機跑過完整 build 驗證過（Docker Hub 的 CDN 網域名稱尤其
# 可能隨時間/地區改變，跟專案其他「依通用知識寫成、沒有實機驗證」的
# 部分同一個性質）。真的跑 build 時如果某個網域被擋，
# /var/log/squid/access.log 會看到 TCP_DENIED，把那個網域加進這個檔案、
# systemctl reload squid 之後重跑 build 就好，不需要再跑這支腳本。
if [ ! -f /etc/squid/allowed_domains.txt ]; then
  cat >/etc/squid/allowed_domains.txt <<'EOF'
# EE image build 白名單網域——一行一個，開頭加 . 代表含子網域。
# 任何網域都可以加進這裡，squid.conf 的 allowed_domains acl 直接讀這個檔案，
# 加完存檔後 systemctl reload squid 就會生效，不需要重跑 squid.sh。
.docker.io
.docker.com
.debian.org
.pypi.org
.files.pythonhosted.org
.github.com
.githubusercontent.com
EOF
fi

cat >/etc/squid/squid.conf <<'EOF'
# 由 squid.sh 自動產生——只服務 podman-network.sh 建的 ansible-builder-network 這個
# podman network（10.90.0.0/24）跟宿主機自己（127.0.0.1），其他來源一律
# 拒絕。full bump：所有 CONNECT 一律解密重簽，http_access 比對到的是
# 解密後的真正 Host，不是 client 宣稱的 CONNECT 目標或 TLS SNI。白名單
# 網域清單拆到 /etc/squid/allowed_domains.txt，不要在這裡夾雜任何網域。
#
# http_port 的憑證選項用 tls-cert=/tls-key=，不是舊的 cert=/key=——Squid
# 5 開始把 http_port 底下跟 TLS 有關的選項全部往 tls- 開頭改名，cert=/
# key= 保留下來只是相容別名，跑 squid -k parse 會印 deprecated 警告（這份
# 設定能不能直接動、有沒有跳出這種警告，實機跑的時候留意一下，trixie 上
# squid-openssl 實際版本號在這個開發環境裡沒有查證的管道）。
#
# http_port 刻意不指定位址（監聽所有介面）——不綁 10.90.0.1
# （ansible-builder-network 這個 podman network 的 gateway）：那個位址
# 是 podman 內部拿來讓 container 連回 host 用的路由機制，不是 squid 或
# OS 本身需要特別去認的東西，綁了它只是讓 squid 的啟動多了一個跟 podman
# 內部生命週期（netavark 延遲建立 bridge/gateway IP，要等第一個 container
# 真正掛上這個 network 才會出現）耦合的脆弱依賴，卻沒有多換到任何實質
# 防護（詳見這支腳本開頭的說明）。真正的存取控制在下面的 `acl localnet`/
# `http_access deny !localnet`（來源位址限制）跟 firewall.sh.j2 的 ufw
# 規則（目的地位址/port 限制）兩層，跟 squid 自己綁在哪個介面上無關。
# 順便附帶一個好處：監聽所有介面本來就自動包含 127.0.0.1，不需要為了
# 讓宿主機自己也能連進來另外加一條 http_port——config.sh 的
# ensure_ee_image() 現在會在宿主機上用 https_proxy=http://127.0.0.1:3128
# 經過這裡拉 base image（debian:13-slim），不讓宿主機自己的
# podman pull 繞過 squid 直接打外網，所以下面 acl localnet 要多認
# 127.0.0.1 這個來源，不然會被 `http_access deny !localnet` 擋掉。
#
# 10.89.0.0/24（ee-build-network）跟 10.90.0.0/24（ansible-builder-network）
# 是兩個各自獨立的 podman network（見 podman-network.sh 的說明）——前者
# 只給 build EE image 用，後者原本也是給 build EE image 用（名字因此
# 得名），現在改給 ansible-navigator 真正執行 playbook 時的 EE 容器用
# （取代原本的 --network=host，見 ansible-navigator.yml），兩者都需要
# 經過這裡連外網（分別是 apt-get/pip，跟 harbor-install.yml 查 GitHub
# release/下載 offline installer tgz），所以都要認。

acl localnet src 10.89.0.0/24
acl localnet src 10.90.0.0/24
acl localnet src 127.0.0.1/32
acl allowed_domains dstdomain "/etc/squid/allowed_domains.txt"
acl SSL_ports port 443
acl Safe_ports port 80 443
acl CONNECT method CONNECT

http_port 3128 ssl-bump \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB \
    tls-cert=/etc/squid/ssl_cert/squidCA.pem \
    tls-key=/etc/squid/ssl_cert/squidCA.pem

sslcrtd_program /usr/lib/squid/security_file_certgen -s /var/lib/squid/ssl_db -M 4MB

acl step1 at_step SslBump1
ssl_bump peek step1
ssl_bump bump all

http_access deny CONNECT !SSL_ports
http_access deny !Safe_ports
http_access deny !localnet
http_access allow localnet allowed_domains
http_access deny all

coredump_dir /var/spool/squid
EOF

squid -k parse

echo "==> 啟用 squid..."
systemctl enable squid
systemctl restart squid

echo "squid 已就緒，監聽 3128（full bump，只服務 10.89.0.0/24、10.90.0.0/24，白名單見 /etc/squid/allowed_domains.txt）"
