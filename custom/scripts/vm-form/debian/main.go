package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/charmbracelet/huh"
)

// 建立 Debian VM 要填的欄位，直接寫在這一個檔案裡——要加欄位就在這裡加
// huh.NewInput()、在下面的 answers 多塞一個 key，一眼就看得到全部欄位，
// 不用額外去開一個 JSON 檔案對照。
//
// 這裡沒有「要不要裝 Harbor」這一題——Harbor 是不是要裝、裝本機的還是接一個
// 已經存在的外部 Harbor，現在是 VM 開機後使用者自己手動跑 bootstrap-services
// 互動決定的事（見 custom/scripts/bootstrap-services/main.go 開頭的說明），
// 不再是 build 這個當下的決定，所以這支表單不再問、也不再輸出 install_harbor。
func main() {
	var vmName string
	var isInfrastructureHost bool

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().Title("VM 名稱").Value(&vmName),
			huh.NewConfirm().
				Title("這台 VM 要成為 infrastructure 網段（10.104.0.0/24）的 host 嗎？").
				Description("這個網段是給不屬於任何單一 cluster、多個 cluster 共用的基礎設施用的（目前只有 Harbor）——同一個網段只能有一個 host（.1），不是每台 control-panel VM 都該選是。只有真的要在這台 VM 上跑共用 Harbor 時才選是；其他 VM 要用這個共用 Harbor，是 host 這邊的人自己用 ~/scripts/wireguard 的 task wireguard:add 產生 peer，手動把印出來的設定帶去那台 VM，這一步不自動化。").
				Value(&isInfrastructureHost),
		),
	)

	if err := form.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
		os.Exit(1)
	}

	answers := map[string]any{
		"vm_name":                vmName,
		"is_infrastructure_host": isInfrastructureHost,
	}

	out, err := json.Marshal(answers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：組不出結果 JSON：%v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}
