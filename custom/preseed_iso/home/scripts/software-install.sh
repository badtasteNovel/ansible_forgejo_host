#!/bin/bash
set -euo pipefail

# 補裝 ~/scripts/wireguard/ 這套工具需要、但不在 pkgsel/include 清單裡的
# 軟體：task（go-task，Taskfile 的執行引擎）、gum（互動式選單）。兩個都裝
# 進 charlie 自己的 ~/.local/bin，不是系統全域路徑（/usr/local/bin
# 之類）——這整支腳本從頭到尾刻意不用 root：這兩個工具只有 charlie
# 自己要用（跑 ~/scripts/wireguard/ 底下的 Taskfile），裝進系統全域路徑
# 給所有使用者共用沒有必要，也不需要為了裝兩個使用者層級的小工具去碰
# dpkg/root 這條更重的路——改用官方 release 的 tar.gz（不是 .deb，.deb
# 要 dpkg -i 才能裝，dpkg 本身就要 root），純粹解壓、複製檔案，整個過程
# charlie 自己的權限就夠。
#
# 透過 charlie 自己的 systemd --user unit 觸發（見
# ~/.config/systemd/user/software-install.service，由 late_command 寫好、
# 靠 loginctl enable-linger charlie 開機自動起，不需要人手動登入/
# 觸發——跟 harbor/caddy-proxy 那套 rootless + linger 的機制一樣），不是
# /srv/init/ 那三個 root 身份的開機 unit——那三個全部是 root 跡，這支
# 刻意不跟它們混在一起。
#
# curl 下載的東西全部要查 checksum 才能用——不是簽名驗證（這兩個專案的
# release 沒有像 Debian ISO 那樣的 GPG 簽名可以驗，見
# custom/scripts/verify-iso/debian.sh 的做法），但至少要確認下載下來的
# 內容跟官方 release 當時公布的 checksums.txt 記錄的雜湊值一致。版本號/
# checksum 都寫死釘住（撰寫這份檔案時查 GitHub release 當下的最新穩定版、
# 實際下載驗證過），不是動態抓「最新版」——理由跟這個專案其他地方釘死
# 版本一樣：可重現、不會因為上游發新版而悄悄改變行為。
#
# 冪等檢查看檔案是不是已經在 ~/.local/bin 底下，不是 command -v——systemd
# --user unit 自己的 PATH 是 systemd 給的預設值，不會包含 ~/.local/bin
# （那是互動式 shell 的 .profile 才會加的事，systemd unit 不會去讀
# .profile），用 command -v 在這個情境下永遠會判斷成「沒裝」，每次開機
# 都重新下載一次——沒有危害（反正有查 checksum），但浪費時間，直接檢查
# 檔案存不存在比較準。

if [ "$(id -u)" -eq 0 ]; then
  echo "錯誤：這支不該用 root 執行——task/gum 是裝進個人的 ~/.local/bin，不需要、也不該碰系統全域路徑或 root 權限" >&2
  exit 1
fi

INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$INSTALL_DIR/task" ]; then
  echo "==> 補裝 task（go-task v3.54.0）..."
  task_tarball="$TMP_DIR/task_linux_amd64.tar.gz"
  curl -fsSL -o "$task_tarball" \
    https://github.com/go-task/task/releases/download/v3.54.0/task_linux_amd64.tar.gz
  echo "680859dbb4d881a9c72d4d9a8f510825450849af8567deacd7302c01124416fb  $task_tarball" | sha256sum -c -
  tar -xzf "$task_tarball" -C "$TMP_DIR" task
  install -m 0755 "$TMP_DIR/task" "$INSTALL_DIR/task"
fi

if [ ! -x "$INSTALL_DIR/gum" ]; then
  echo "==> 補裝 gum（v2.0.2）..."
  gum_tarball="$TMP_DIR/gum_2.0.2_Linux_x86_64.tar.gz"
  curl -fsSL -o "$gum_tarball" \
    https://github.com/charmbracelet/gum/releases/download/v2.0.2/gum_2.0.2_Linux_x86_64.tar.gz
  echo "d842e06d93dbed90af48cb8dd10698db6f22e331fc40346bb37bbc753109edc2  $gum_tarball" | sha256sum -c -
  tar -xzf "$gum_tarball" -C "$TMP_DIR" gum_2.0.2_Linux_x86_64/gum
  install -m 0755 "$TMP_DIR/gum_2.0.2_Linux_x86_64/gum" "$INSTALL_DIR/gum"
fi

echo "software-install 完成：task/gum 已裝進 $INSTALL_DIR"
