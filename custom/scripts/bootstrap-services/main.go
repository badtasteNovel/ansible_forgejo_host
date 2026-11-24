package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/huh"
)

// bootstrap-services 只負責一件事：互動問「要不要在本機裝 Harbor（還是接一個
// 已經存在的外部 Harbor）」，把答案整理成 JSON，丟給同一個資料夾裡
// services/apply.sh 去做真正的工作（pull image、podman login、寫
// registries.conf.d、跑 ansible-navigator……——apply.sh 自己又拆成
// env.sh/harbor.sh/caddy.sh 幾支，見各自開頭的說明）。這些事交給 shell 來做
// 比較自然——curl/jq/podman 這些指令列工具本來就是殼層的拿手戲，不需要在
// Go 裡面包一層又一層去重做 shell 工具已經做得很好的事。Go 負責的部分只剩
// 「表單」這個 shell 做不好的事。
//
// services/ 整個資料夾都是一次性的：apply.sh 成功跑完，這支程式會把整個
// services/ 資料夾跟自己一起刪掉（道理跟 bootstrap-sudo 一樣，見那支程式
// 開頭的說明）；apply.sh 失敗的話整個資料夾留著，方便修完問題後直接重跑
// services/apply.sh（不用再填一次表單——失敗時的錯誤訊息裡會提示怎麼重跑）。
//
// 沒有另外用一個標記檔案判斷「跑過沒有」——跟 bootstrap-sudo/bootstrap-firewall.sh
// 一樣，自我刪除本身就是「已經跑過」的紀錄：成功之後 bootstrap-services 跟
// services/ 都不在了，想重跑也找不到東西可以跑，不需要額外的標記檔案來擋。
//
// 選 y（本機裝 Harbor）：Enter 送出表單後直接開始裝，不用再填別的。
// 選 n（接外部既有的 Harbor）：Enter 之後追問外部 Harbor 的網址 + 登入用的
// 帳密（robot 或一般帳號都可以），任何一個欄位空白都視為沒填好、整支程式
// exit 1，不會呼叫 apply.sh。

type answers struct {
	WireguardVMAddress string `json:"wireguard_vm_address"`
	InstallHarbor      bool   `json:"install_harbor"`
	HarborHostname     string `json:"harbor_hostname"`
	HarborURL          string `json:"harbor_url"`
	HarborUsername     string `json:"harbor_username"`
	HarborPassword     string `json:"harbor_password"`
}

func main() {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "錯誤：請用 sudo 執行這支程式（例如：sudo ~/bootstrap/bootstrap-services）")
		os.Exit(1)
	}

	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：找不到自己的執行檔路徑：%v\n", err)
		os.Exit(1)
	}
	servicesDir := filepath.Join(filepath.Dir(exe), "services")
	applyScript := filepath.Join(servicesDir, "apply.sh")
	if _, err := os.Stat(applyScript); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：找不到 %s（應該跟這支程式放在同一個資料夾下的 services/ 子資料夾）：%v\n", applyScript, err)
		os.Exit(1)
	}

	ans := answers{}

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("這台 VM 自己的 WireGuard 位址").
				Description("用 sudo wg show 查，輸入範例：10.105.0.0/24").
				Value(&ans.WireguardVMAddress),
			huh.NewNote().
				Title("設定這台 VM 的 Harbor pull-through cache").
				Description("caddy-proxy 一定會裝；Harbor 是選用的——可以在本機裝一份，也可以接一個已經存在的外部 Harbor。"),
			huh.NewConfirm().
				Title("要在本機安裝 Harbor 嗎？").
				Value(&ans.InstallHarbor),
		),
	)
	if err := form.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
		os.Exit(1)
	}

	if strings.TrimSpace(ans.WireguardVMAddress) == "" {
		fmt.Fprintln(os.Stderr, "錯誤：沒有填這台 VM 的 WireGuard 位址，不會做任何變更")
		os.Exit(1)
	}

	if ans.InstallHarbor {
		// 固定預設值，使用者可以直接接受或改掉——不需要去讀任何檔案當預設值：
		// harbor.yml/harbor.caddy 這兩個樣板現在是 harbor-install.yml 在
		// VM 上才渲染的（見該檔案開頭的說明），這支程式問完這個問題之後
		// 才會去呼叫 apply.sh（進而跑到 harbor-install.yml），問的當下
		// harbor.yml 根本還不存在，沒有「真實值」可以讀。這裡填的值會透過
		// --extra-vars 傳進 harbor-install.yml，直接變成 harbor.yml/
		// harbor.caddy 渲染出來的真正內容，不會有脫鉤的問題——這個值從頭
		// 到尾只有這裡這一個來源。
		ans.HarborHostname = "harbor.internal"

		hostnameForm := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("本機 Harbor 要用的 hostname（caddy-proxy 後面的 vhost 名稱）").
					Description("已經帶入預設值，直接 Enter 接受就好，或自己改。").
					Value(&ans.HarborHostname),
			),
		)
		if err := hostnameForm.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
			os.Exit(1)
		}
		if strings.TrimSpace(ans.HarborHostname) == "" {
			fmt.Fprintln(os.Stderr, "錯誤：沒有填 Harbor 的 hostname，不會做任何變更")
			os.Exit(1)
		}
	} else {
		externalForm := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("外部 Harbor 的網址（例如 harbor.other-vm.internal:443，不含 https://）").
					Value(&ans.HarborURL),
				huh.NewInput().
					Title("登入帳號（一般帳號或 robot 帳號都可以）").
					Value(&ans.HarborUsername),
				huh.NewInput().
					Title("登入密碼／robot secret").
					EchoMode(huh.EchoModePassword).
					Value(&ans.HarborPassword),
			),
		)
		if err := externalForm.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
			os.Exit(1)
		}
		if strings.TrimSpace(ans.HarborURL) == "" {
			fmt.Fprintln(os.Stderr, "錯誤：沒有填外部 Harbor 的網址，不會做任何變更")
			os.Exit(1)
		}
		if strings.TrimSpace(ans.HarborUsername) == "" || strings.TrimSpace(ans.HarborPassword) == "" {
			fmt.Fprintln(os.Stderr, "錯誤：外部 Harbor 的登入帳密沒填完整，不會做任何變更")
			os.Exit(1)
		}
	}

	payload, err := json.Marshal(ans)
	if err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：組不出答案 JSON：%v\n", err)
		os.Exit(1)
	}

	cmd := exec.Command(applyScript)
	cmd.Stdin = strings.NewReader(string(payload))
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：%s 執行失敗，不會刪除 services/ 資料夾或這支程式——修完問題後直接重跑即可，不用再跑一次表單，用同一份 JSON 餵給 stdin：\n", applyScript)
		fmt.Fprintf(os.Stderr, "  echo '%s' | sudo %s\n", string(payload), applyScript)
		fmt.Fprintf(os.Stderr, "原始錯誤：%v\n", err)
		os.Exit(1)
	}

	// 跑完就自刪——這是一次性安裝程式，不是常駐工具，留著只會變成一支隨時
	// 可以重新觸發 Harbor/caddy-proxy 安裝流程的程式。exe 是最前面已經查過
	// 的執行檔路徑，不用再查一次。
	os.RemoveAll(servicesDir)
	if err := os.Remove(exe); err != nil {
		fmt.Fprintf(os.Stderr, "警告：自我刪除失敗，手動刪掉 %s 比較安全：%v\n", exe, err)
	}
}
