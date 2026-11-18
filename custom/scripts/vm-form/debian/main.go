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

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().Title("VM 名稱").Value(&vmName),
		),
	)

	if err := form.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
		os.Exit(1)
	}

	answers := map[string]any{
		"vm_name": vmName,
	}

	out, err := json.Marshal(answers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：組不出結果 JSON：%v\n", err)
		os.Exit(1)
	}
	fmt.Println(string(out))
}
