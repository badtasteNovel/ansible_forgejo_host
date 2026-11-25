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
			// 用 Select 不用 Confirm——Confirm 的 Yes/No 兩個按鈕，目前選到
			// 哪一個純粹只靠背景顏色反白區分，沒有任何文字符號，終端機
			// 顏色顯示不出來（或者輸出被轉貼到別的地方、顏色跟著不見）
			// 的時候完全看不出來選到哪個。Select 預設會在目前選到的選項
			// 前面加一個固定的 "> " 文字游標，不管顏色顯不顯示都看得到，
			// 同一個問題用 Select 不會發生。
			huh.NewSelect[bool]().
				Title("這台 VM 要成為 infrastructure 網段（10.104.0.0/24）的 host 嗎？").
				Description("是否要把這台 VM 設成 10.104.0.1/32 的 WireGuard 位址").
				Options(
					huh.NewOption("Yes", true),
					huh.NewOption("No", false),
				).
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
