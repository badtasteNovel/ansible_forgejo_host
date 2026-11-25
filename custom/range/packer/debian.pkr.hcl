# 用 WSL2 側 `task range:build` 已經產好的 is_dev ISO（custom/generated/iso/
# <vm_name>/<vm_name>-preseed.iso）開一台 Hyper-V VM，跑完整套 preseed 無人值守
# 安裝 + /srv/init/ 四個 systemd unit 的鏈（podman-network → firewall →
# software-install → finalizer），再加一個只有 is_dev 才會生效的
# dev-range-poweroff.service，等整條鏈跑完自動關機——是這支 Packer build
# 唯一知道「裝機真的完成了」的方式。
#
# communicator 故意設成 "none"：這台 VM 的 sshd 雖然在 is_dev 時沒有鎖
# WireGuard（見 preseed.cfg.j2 is_dev 分支），但 Packer 跑在 Windows 上，
# 這個階段還不確定 Hyper-V 虛擬網路卡會配到哪個位址（DHCP、要等 VM 開機
# 才知道），沒有通訊器可用也沒關係——ISO 本身已經是全自動（remaster-iso.sh
# 改過開機選單的 timeout/default，不需要 boot_command），裝完機、開機、
# /srv/init 鏈跑完就自己關機，Packer 只需要等 VM 的電源狀態變成 Off。
#
# 這個檔案沒有在真實 Hyper-V 環境跑過驗證——跟這個專案其他地方的 .vmx/
# vmkfstools 一樣的誠實註記，第一次跑之前自己先核對一次欄位。
packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.3"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "iso_path" {
  type        = string
  description = "task range:build 印出來的那個路徑，custom/generated/iso/<vm_name>/<vm_name>-preseed.iso——必帶，沒有預設值，故意不去猜哪個 vm_name"
}

variable "vm_name" {
  type        = string
  default     = "debian-range"
  description = "Hyper-V 裡這台建置用 VM 的名字，跟靶場 ISO 本身的 vm_name 無關（那個只影響 ISO 內容），這裡單純是 Hyper-V Manager 看到的顯示名稱"
}

variable "switch_name" {
  type        = string
  default     = "Default Switch"
  description = "要接哪個 Hyper-V virtual switch——建議用一個 External（橋接實體網卡）的 switch，這樣 VM 會拿到跟 lan_subnet 同網段的 DHCP IP，才吃得到 firewall.sh.j2 is_dev 分支額外放行的那條 ufw 規則；用內建的 Default Switch（NAT）理論上也能開機完成安裝，但事後 Vagrant/vagrant ssh 要連得到這台 VM 得另外處理 port forwarding，不在這份範本的範圍內"
}

variable "cpus" {
  type    = number
  default = 2 # 跟 playbook/control-panel/debian.yml 的 vm_cpus 預設值一致，純粹方便對照，沒有強制要求一樣
}

variable "memory_mb" {
  type    = number
  default = 2048 # 跟 vm_memory_mb 預設值一致，同上
}

variable "disk_size_mb" {
  type    = number
  default = 30720 # 30GB，跟 vm_disk_system_gb 預設值一致——靶場只需要系統碟，資料碟/Harbor 碟不是每次都需要，用不到就不先建
}

source "hyperv-iso" "debian_range" {
  vm_name   = var.vm_name
  cpus      = var.cpus
  memory    = var.memory_mb
  disk_size = var.disk_size_mb

  # Generation 1（BIOS）——這個專案的 ESXi .vmx 也沒有特別設成 EFI
  # firmware（見 debian.vmx.j2/CLAUDE.md 的 guestOS/virtualHW.version
  # 註記），remaster-iso.sh 的開機自動化同時改了 isolinux（BIOS）跟
  # grub.cfg（UEFI）兩套選單，理論上兩種 generation 都能開機，這裡選
  # Generation 1 只是跟現有 ESXi 路徑的假設更接近，不是因為 Generation 2
  # 不支援。
  generation = 1

  iso_url      = var.iso_path
  iso_checksum = "none" # 本機剛產出的 ISO，不是從網路下載的第三方檔案，不需要額外算 checksum 比對

  switch_name = var.switch_name

  # 不設 boot_command——ISO 已經是全自動安裝（remaster-iso.sh 把開機選單
  # 的 timeout 都改短、預設項目指到帶 preseed 參數的那一項），開機之後
  # 完全不需要任何鍵盤輸入。
  boot_wait = "2s"

  communicator     = "none"
  # 保守估計的上限，實機數字還沒量過——包含完整 preseed 安裝（debootstrap +
  # pkgsel 一長串套件，podman/buildah/ansible-core/squid-openssl 這些都不小）
  # 跟 /srv/init 四個 unit 跑完（software-install.sh 要 curl task/gum
  # 外加 pipx install ansible-navigator，是這條鏈裡最慢的一段）。
  # bootstrap-services 互動流程（ensure_ee_image 第一次 podman build）不在
  # 這個時間範圍內——那是人工 SSH 進去才會跑的事，不屬於這條自動鏈。
  shutdown_timeout = "45m"
}

build {
  sources = ["source.hyperv-iso.debian_range"]

  # vagrant post-processor 把這次建置的結果包成一個本機 box（provider
  # 強制指定 hyperv，不讓它用 source type 自動猜）。output_vagrantfile
  # 這個 provider-specific 設定沒有特別需要，Vagrantfile 本身另外寫在
  # custom/range/Vagrantfile，不靠 Packer 產生的那份。
  #
  # output 這個相對路徑是相對「執行 packer build 當下的工作目錄」解析，
  # 不是相對這份 .pkr.hcl 檔案自己的位置——Packer 本來就是這樣處理相對
  # 路徑的，不是這個檔案的特例。這裡假設的慣例固定是「先 cd 進
  # custom/range/packer/ 再跑 packer build debian.pkr.hcl」，所以往上跳
  # 一層再進 output/，對到的就是 custom/range/output/。從別的工作目錄
  # 呼叫這份範本，這個路徑就會解析到別的地方，不是這裡假設的位置。
  post-processor "vagrant" {
    output             = "../output/${var.vm_name}.box"
    provider_override  = "hyperv"
  }
}
