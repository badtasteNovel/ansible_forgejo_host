#!/bin/bash
set -euo pipefail

# 裝 task（go-task）、gum 兩個這個專案需要、但不在 pkgsel/include 清單裡的
# 工具，整支以 rootless 身份跑（systemd unit 的 User={{ vm_user }} 這一行，
# 不帶 + 號）：只做下載、checksum 驗證、解壓到暫存目錄這些碰不可信下載內容
# 的工作，完全不碰 /usr/local/bin 這個系統全域路徑——那是 root 的事，由
# software-install.service 自己另外兩行帶 + 號的 ExecStart（mv 到
# /usr/local/bin）負責，見 preseed.cfg.j2 裡那個 unit 的定義。
# ansible-navigator 也不在這裡裝：pipx install --global 的目的地
# （/opt/pipx、/usr/local/bin）預設是 root:root，這個專案刻意不去 chown
# 這兩個系統路徑（改動範圍太大），所以 pipx install --global 這一步本來
# 就需要 root，直接交給 unit 裡那一行帶 + 號的 ExecStart 處理，不屬於這支
# 腳本的工作範圍。
#
# 暫存目錄不是這支腳本自己用 mktemp 開的，是 unit 裡的 RuntimeDirectory=
# software-install 讓 systemd 自己建好（/run/software-install，ownership
# 自動設成 User=/Group= 指定的帳號，所以這支腳本寫得進去）、再透過
# ${RUNTIME_DIRECTORY} 參數展開傳成這支腳本的 $1——systemd 的每一行
# ExecStart= 都是各自獨立 fork 出來的 process，彼此不共享 shell 變數，靠
# systemd 自己管理這個路徑（不管是這支腳本、還是 unit 裡後面幾行帶 + 號的
# ExecStart）比手動 mktemp 再兩邊各自硬寫同一個前綴字串更不會對不起來。
#
# curl 下載的東西全部要查 checksum 才能用——不是簽名驗證（這兩個 Go
# 專案的 release 沒有像 Debian ISO 那樣的 GPG 簽名可以驗，見
# custom/scripts/verify-iso/debian.sh 的做法），但至少要確認下載下來的
# 內容跟官方 release 當時公布的 checksums.txt 記錄的雜湊值一致。版本號/
# checksum 都寫死釘住（撰寫這份檔案時查 GitHub release 當下的最新穩定版、
# 實際下載驗證過），不是動態抓「最新版」——理由跟這個專案其他地方釘死
# 版本一樣：可重現、不會因為上游發新版而悄悄改變行為。
#
# 兩個 curl 都帶 --retry 10 --retry-delay 3 --retry-all-errors——實機撞過
# 開機當下這支 service 真正跑起來的那一瞬間，DNS 還沒準備好（curl: (6)
# Could not resolve host），systemd unit 已經加了 Wants=/After=
# network-online.target（見 preseed.cfg.j2），但這台機器的網路是
# dhcpcd（不是 ifupdown/NetworkManager/systemd-networkd），沒有確認
# dhcpcd 的 systemd 整合有正確掛上 network-online.target——加了那個
# ordering 之後問題照樣重現，等於完全沒被等到。改成讓 curl 自己重試，
# 不管底層用哪種網路管理工具都有效，不用去猜/依賴哪個 systemd target
# 有沒有正確接線。--retry-all-errors 是必要的：curl 預設 --retry 只在
# 特定 HTTP 5xx/408/429 這類「暫時性」錯誤才重試，DNS 解析失敗
# （CURLE_COULDNT_RESOLVE_HOST）不在預設清單裡，不加這個旗標遇到這個
# 錯誤還是會直接放棄，retry 次數再多都沒用。

STAGE_DIR="$1"

if ! command -v task >/dev/null 2>&1; then
  echo "==> 裝 task（go-task v3.54.0）..."
  task_tarball="$STAGE_DIR/task_linux_amd64.tar.gz"
  curl -fsSL --retry 10 --retry-delay 3 --retry-all-errors -o "$task_tarball" \
    https://github.com/go-task/task/releases/download/v3.54.0/task_linux_amd64.tar.gz
  echo "680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb  $task_tarball" | sha256sum -c -
  tar -xzf "$task_tarball" -C "$STAGE_DIR" task
fi

if ! command -v gum >/dev/null 2>&1; then
  echo "==> 裝 gum（v2.0.2）..."
  gum_tarball="$STAGE_DIR/gum_2.0.2_Linux_x86_64.tar.gz"
  curl -fsSL --retry 10 --retry-delay 3 --retry-all-errors -o "$gum_tarball" \
    https://github.com/charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_x86_64.tar.gz
  echo "d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2  $gum_tarball" | sha256sum -c -
  tar -xzf "$gum_tarball" -C "$STAGE_DIR" gum_2.0.2_Linux_x86_64/gum
  mv "$STAGE_DIR/gum_2.0.2_Linux_x86_64/gum" "$STAGE_DIR/gum"
fi

echo "software-install.sh（rootless 階段）完成：task/gum 已驗證、解壓到 $STAGE_DIR，等 unit 裡後續的 root 階段 mv 進 /usr/local/bin"
