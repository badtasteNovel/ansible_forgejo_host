

# Debian VM 自動化建置（ESXi standalone host）
![Build status](https://img.shields.io/badge/ansible-automation-blue)
![Target](https://img.shields.io/badge/target-Debian_13_(trixie)-red)
![Hypervisor](https://img.shields.io/badge/hypervisor-ESXi_standalone-informational)

> 用 Ansible + preseed 全自動建置一台 Debian 13 VM，跑在沒有 vCenter 的單台 ESXi host 上；VM 同時是 WireGuard server，`charlie` 這個 sudo 使用者沒有密碼、只能用 SSH 金鑰登入。全程不碰任何 vSphere/ESXi API，只靠 SSH/scp + ESXi 自己的 `vmkfstools`。**Register VM 跟 Power On 是刻意保留的手動步驟**，自動化到此為止。
---
## 功能(control-panel)

- 🖥️ **control-panel軟體架構**：vm 的設計主要是為了control-panel而設計。
- 🌐 **cluster內部所有節點透過wireguard進行連線**：以此專案建立的vm，被賦予10.105.0.1 的ip 位置，作為 cluster 的 control-panel，用10.105.0.0/24 進行節點溝通。

---

## 🛠️ 技術棧 (Tech Stack)

- **自動化**：Ansible（`ansible-core` + `community.crypto`、`ansible.posix`）
- **ISO 重新封裝**：`xorriso`（唯讀 `-osirrox` 解包，免 `mount`/`sudo`/loop device）、`isolinux`
- **互動介面**：`gum`（選單/輸入）、Go + [`huh`](https://github.com/charmbracelet/huh)（`vm-form` 建 VM 表單、`bootstrap-sudo` 救援表單）
- **VM 層**：ESXi 本地 CLI（`vmkfstools` 建虛擬磁碟）、手寫 `.vmx`
- **網路**：WireGuard（`wg`/`wg-quick`）、`ufw`、`chrony`
- **工作流程**：[Task](https://taskfile.dev/)（`Taskfile.yaml` + `custom/scripts/tasks/go-task/` 下的命名空間檔）
- **連線**：`sshpass`（非互動帶密碼 SSH 進 hypervisor）、`jq`（解析 `manifest.json`）

---
## 用前環境設置 (Environment Setup)

### 1. **安裝 go-task**
```bash
sh -c "$(curl -ssL https://taskfile.dev/install.sh)" -- -d -b /tmp && sudo mv /tmp/task /usr/local/bin/task && task --version
```
### 2. **預設powershell為預設命令**(windows)
```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
```
### 3. **安裝openssh-server**(windows)
安裝 openSSH server
```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```
啟動服務，並設成開機自動啟動
```powershell
Start-Service sshd
```
```powershell
Set-Service -Name sshd -StartupType 'Automatic'
```
確認防火牆規則有沒有自動建立（安裝時通常會自動加一條）

```powershell
Get-NetFirewallRule -Name *ssh* | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -RemoteAddress 127.0.0.1
```

如果第 3 步查不到規則(沒有自動建立),補上:
```powershell
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -RemoteAddress 127.0.0.1
```
### 4. **查詢 127.0.0.1 是否已成為限制ip**
```powershell
Get-NetFirewallRule -Name *ssh* | Get-NetFirewallAddressFilter
```
## 📦 安裝指南 (Installation)

1. **Clone 專案**
   ```bash
   git clone <this-repo>
   cd ansible
   ```

2. **安裝所有本機工具**（Ansible、`xorriso`/`isolinux`、`gum`、`jq`、`sshpass`、`wireguard-tools`、Go）
   ```bash
   task install
   ```

3. **設定 hypervisor 連線資訊**
   ```bash
   cp custom/.env.example custom/.env
   # 編輯 custom/.env，填入 HYPERVISOR_HOSTNAME / USERNAME / PASSWORD / DATASTORE / NETWORK
   ```

4. **放進官方 Debian ISO**
   ```bash
   # custom/iso/debian/ 底下放一份 netinst ISO，檔名要對上 custom/iso/manifest.json 裡 debian 的 iso-path
   task verify-iso   # 可選，但建議先確認是官方未竄改版本
   ```

---

## 🚀 使用方式 (Usage)

**建立一台 Debian VM**（互動問 VM 名稱、要留幾個 WireGuard peer 名額）：

```bash
task build:debian
```

跑完會把 preseed ISO、`.vmx`、兩顆 `vmkfstools` 建好的虛擬磁碟（系統碟 + 資料碟）都上傳到 `custom/.env` 指定的 datastore，並印出剩下的手動步驟：

```text
1. 登入 ESXi Host Client，瀏覽到該 .vmx，Register VM
2. 手動 Power On
3. preseed 無人值守安裝跑完後，查一下 VM 的 LAN IP（唯一用途：等 task add-peer 要用）
4. task add-peer —— 把目前這台機器加進 WireGuard、接通隧道
5. 之後 SSH 固定走 WireGuard 位址 10.105.0.1，不是 LAN IP
```

**把目前這台機器接進某台 VM 的 WireGuard 隧道**（VM 要先開機、知道它的 LAN IP）：

```bash
task add-peer
```

互動選要接哪一台 VM、輸入它的 IP；如果偵測到是 WSL2，會額外幫原生 Windows 也認領一個獨立的 peer，產生一份 WireGuard for Windows 可以直接 import 的 `.conf`。

**其他常用指令**：

```bash
task select-iso    # 互動選一個已登記的 OS，印出 ISO 路徑
task verify-iso    # 驗證 ISO 是官方未竄改版本
task clean         # 清掉 build 產物（keys 會額外二次確認）
```

---

## 📂 資料夾結構 (Directory Structure)

```text
├── playbook/
│   ├── control-panel/debian.yml   # 主要進入點：產生金鑰/preseed/ISO/.vmx，上傳到 datastore
│   └── wsl/
│       ├── add-peer.yml           # 把控制端（WSL2 + 原生 Windows）接進 VM 的 WireGuard 隧道
│       └── windows-ping.yml       # 測試 WinRM 能不能連上本機 Windows（見 inventory/windows.ini）
├── custom/
│   ├── iso/                       # 放官方來源 ISO + manifest.json（OS → iso-path/build-path）
│   ├── generated/                 # build 產物：preseed/、iso/、keys/（gitignored，只留 manifest/.gitkeep）
│   ├── template/                  # Jinja2 模板——本來放在 roles/*/templates/，後來發現這個專案根本
│   │   │                          # 沒在用真正的 Ansible role 機制（role 不能有自己的 hosts:，這裡
│   │   │                          # 全部靠明確路徑引用），搬過來跟其他 custom/ 底下的東西放一起
│   │   ├── wireguard_control_panel/   # VM 端 wg0.conf.j2（server）
│   │   └── wireguard_agent/           # 控制端 wg0.conf.j2（peer，含 WSL2 跟原生 Windows 共用）
│   ├── preseed_iso/                # Debian 無人值守安裝的完整來源：template/（preseed.cfg.j2、
│   │   │                           # debian.vmx.j2，純粹是渲染/打包用的工作目錄，不對應 VM 上任何
│   │   │                           # 路徑）、bootstrap/（裝機時烘焙進去、一次性的）跟 srv/（VM 的
│   │   │                           # /srv 底下那些東西，工作目錄結構直接對齊最終 /srv 的結構）
│   │   ├── template/                  # preseed.cfg.j2、debian.vmx.j2——不對應 VM 上任何路徑
│   │   ├── bootstrap/                 # 對齊 VM 上 ~{{ vm_user }}/bootstrap/ 的結構
│   │   └── srv/                       # 對齊 VM 上 /srv 的結構（srv/ansible/、srv/harbor/、srv/nginx/...）
│   ├── scripts/
│   │   ├── remaster-iso/debian.sh     # 重新封裝 ISO（注入檔案、改開機自動選單）
│   │   ├── verify-iso/debian.sh       # 驗證官方未竄改 ISO
│   │   ├── vm-form/debian/            # huh 表單：問 VM 名稱
│   │   ├── bootstrap-sudo/            # 交叉編譯進 ISO 的一次性救援程式
│   │   └── tasks/
│   │       ├── go-task/               # Taskfile 的命名空間子檔（install/build/verify-iso/windows）
│   │       └── ansible/               # 共用的 Ansible task 片段（include_tasks 引用，同樣原本在 roles/*/tasks/）
│   │           ├── wireguard_keys/        # 金鑰產生/peer 名額產生/認領/標記已認領
│   │           └── load_env/              # 解析 custom/.env 成 Ansible fact（不經過 OS 環境變數，見下方 inventory/）
│   └── .env.example               # hypervisor/Windows 連線資訊範本（.env 本身 gitignored）
├── inventory/
│   ├── windows.ini                 # WinRM 連本機 Windows 用（WSL2 場景，透過 Enable-PSRemoting 開的 listener）
│   └── group_vars/windows.yml      # windows group 的連線帳密，讀 custom/scripts/tasks/ansible/load_env 解析出來的 custom/.env
├── group_vars/ host_vars/ roles/   # Ansible 官方骨架，目前皆為空，各自 .gitkeep 佔位（這個專案沒用到真正的 role 機制，見上方 custom/template/ 的說明）
├── requirements.yml                # ansible-galaxy collections（community.crypto、ansible.posix、ansible.windows）
└── Taskfile.yaml                   # 任務入口，include custom/scripts/tasks/go-task/ 底下的檔案
```

---

## 🤝 開發慣例 (Conventions)

這是個人機房自動化專案，目前不收外部 PR。commit message 走 Conventional Commits 風格（`feat:`、`fix:`、`docs:` 等前綴 + 中文說明）。細節決策（為什麼不用 vSphere API、為什麼 WireGuard 是強制而非選用、`.vmx`/`vmkfstools` 的已知未驗證假設等）都記錄在 [`CLAUDE.md`](CLAUDE.md)，改動前請先讀過。

---

## ⚠️ 已知限制

- `.vmx` 語法與 `vmkfstools` 用法是依官方文件寫的，尚未在真實 ESXi host 上完整驗證過。
- `charlie` 跟 `root` 都沒有密碼；若 WireGuard 或 SSH 本身掛掉，除了 ESXi console（需要密碼，兩者都沒有）之外沒有救援路徑——這是刻意接受的 tradeoff，細節見 `CLAUDE.md`。`bootstrap-sudo` 是唯一的事後補救手段，且要在還能 SSH 進去時自己執行。

## 專案相關
- ```custom/preseed_iso/template/preseed.cfg.j2``` 渲染成 preseed.cfg，打包入 iso ，在使用者安裝 debian 的時候使debian-installer 讀取
