#!/bin/bash
set -euo pipefail

# 設定 squid（套件安裝見 preseed.cfg.j2 的 pkgsel/include，這支只負責產生
# CA、寫設定、啟用服務），當 EE image 建置（ansible-builder build →
# podman build，見 config.sh 的 ensure_ee_image()）專用的正向代理——full bump 模式：對每個
# CONNECT 一律解密、用自己的 CA 重簽，http_access 比對到的是解密後真正的
# Host，不是 client 自稱的 CONNECT 目標或 TLS SNI（這兩者都可能跟封包裡
# 實際的 Host 不一致，是只做 peek+splice 會留下的洞，討論過後決定接受
# full bump 多出來的成本——多一張 CA 要塞進 build container 的信任鏈，見
# execution-environment.yml 跟 config.sh）。
#
# apply.sh 呼叫這支的時機要排在 ensure_ee_image 之前（squid 沒先跑起來，
# EE build 連不出去）；跟 harbor.sh/nginx.sh 不一樣，這支不需要表單填的
# 任何欄位，所以不用被 source 進去定義函式讓 apply.sh 呼叫——直接執行
# 就好。
#
# 放在 bootstrap/services/（跟著互動式的 bootstrap-services 表單跑一次），
# 不是放進 srv/init/（開機就自動跑、不需要人介入）：squid 唯一的消費者
# ensure_ee_image() 本身就只會從 apply.sh 這條互動流程被呼叫到，沒有任何
# 地方在開機當下自動建 EE image，所以 squid 沒有必要比 bootstrap-services
# 更早就位——跟 harbor.sh/nginx.sh 同一個道理，簡單起見直接沿用一次性表單
# 流程的既有慣例就好。這也代表 podman-network.sh 建的 ansible-builder-network network
# 這時一定已經存在（srv/init/ 那三支開機就自動跑完了，遠早於使用者真的
# SSH 進來填表單的時間點），下面綁死在那個 network 的 gateway 位址不會撞
# 到「network 還沒建好」的狀況。
#
# 跟 podman-network.sh 綁在一起看：squid 監聽在 10.90.0.1（ansible-builder-network 這個
# network 的 gateway，podman-network.sh 用 --gateway 固定寫死，不是讓
# podman 自己選第一個可用位址）。build container 只需要連到自己這個
# network 的 gateway——這是 bridge 內部的事，不需要 FORWARD chain 開洞，
# firewall.sh.j2 因此只需要一條單純的 ufw allow（INPUT chain），詳見那支
# 腳本自己的說明。

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
if ! command -v squid >/dev/null 2>&1; then
  echo "錯誤：找不到 squid——應該已經在 preseed.cfg.j2 的 pkgsel/include 裝好了，golden image 建置流程有問題" >&2
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
  openssl req -new -newkey rsa:4096 -sha256 -days 3650 -nodes -x509 \
    -keyout "$SSL_CERT_DIR/squidCA.key" \
    -out "$SSL_CERT_DIR/squidCA.crt" \
    -subj "/CN=debian-vm squid full-bump CA (EE build only)"
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

# 動態簽發憑證用的資料庫——squid 第一次啟動前沒初始化過的話，ssl-bump 會
# 直接失敗。這個目錄本身不是設定檔，是 security_file_certgen 自己管理的
# 資料庫檔案，初始化過一次之後就一直沿用，不需要每次重跑這支腳本都重建。
if [ ! -d "$SSL_DB_DIR" ]; then
  echo "==> 初始化 squid 的動態憑證資料庫..."
  /usr/lib/squid/security_file_certgen -c -s "$SSL_DB_DIR" -M 4MB
  chown -R proxy:proxy "$SSL_DB_DIR"
fi

# 白名單網域清單——故意拆成獨立檔案，不是寫死在 squid.conf 裡：以後任何
# 網域要放進白名單，直接編輯這個檔案（一行一個網域，開頭加 . 代表含子
# 網域）就好，不用碰 squid.conf、也不用重新理解整份設定。只在第一次建立
# 時寫入 seed 內容，重跑這支腳本不會蓋掉之後手動加上去的網域。
#
# 目前的 seed 內容是依據 execution-environment.yml 的 base_image
# （quay.io/ansible/creator-ee）跟它 additional_build_steps 那一行
# `microdnf install ... || (apt-get update && apt-get install ...)` 猜出來的
# 常見套件鏡像站網域，沒有實機跑過完整 build 驗證過——這個 base image
# 實際繼承自哪個發行版、預設用哪個鏡像站，在這個開發環境裡沒有查證的
# 管道，跟專案其他「依通用知識寫成、沒有實機驗證」的部分（.vmx guestOS
# 字串、virtualHW.version）同一個性質。真的跑 build 時如果某個網域被擋，
# /var/log/squid/access.log 會看到 TCP_DENIED，把那個網域加進這個檔案、
# systemctl reload squid 之後重跑 build 就好，不需要再跑這支腳本。
if [ ! -f /etc/squid/allowed_domains.txt ]; then
  cat >/etc/squid/allowed_domains.txt <<'EOF'
# EE image build 白名單網域——一行一個，開頭加 . 代表含子網域。
# 任何網域都可以加進這裡，squid.conf 的 allowed_domains acl 直接讀這個檔案，
# 加完存檔後 systemctl reload squid 就會生效，不需要重跑 squid.sh。
.fedoraproject.org
.centos.org
.redhat.com
.debian.org
.ubuntu.com
EOF
fi

cat >/etc/squid/squid.conf <<'EOF'
# 由 squid.sh 自動產生——只服務 podman-network.sh 建的 ansible-builder-network 這個
# podman network（10.90.0.0/24），其他來源一律拒絕。full bump：所有
# CONNECT 一律解密重簽，http_access 比對到的是解密後的真正 Host，不是
# client 宣稱的 CONNECT 目標或 TLS SNI。白名單網域清單拆到
# /etc/squid/allowed_domains.txt，不要在這裡夾雜任何網域。

acl localnet src 10.90.0.0/24
acl allowed_domains dstdomain "/etc/squid/allowed_domains.txt"
acl SSL_ports port 443
acl Safe_ports port 80 443
acl CONNECT method CONNECT

http_port 10.90.0.1:3128 ssl-bump \
    generate-host-certificates=on \
    dynamic_cert_mem_cache_size=4MB \
    cert=/etc/squid/ssl_cert/squidCA.pem \
    key=/etc/squid/ssl_cert/squidCA.pem

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

echo "squid 已就緒，監聽 10.90.0.1:3128（full bump，白名單見 /etc/squid/allowed_domains.txt）"
