package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/charmbracelet/huh"
)

const targetUser = "charlie"

// 救援用的一次性腳本：平常 charlie 完全沒有密碼（只能用 SSH 金鑰登入），這是
// 刻意的設計；但如果 WireGuard 或 SSH 本身掛了，連 ESXi console 都進不去，因為
// console 登入需要密碼，而 charlie 跟 root 都沒有密碼。這支程式讓使用者在還能
// SSH 進去的時候，自己決定要不要開這條退路：互動問一個密碼、把 charlie 加進
// sudo group、設好密碼，然後自己刪除自己——避免留著一支「隨便一個碰到這台機器
// 的人都能直接加密碼、拿 sudo」的程式在機器上。
//
// 設完密碼後，會把 /etc/sudoers.d/charlie 那個 NOPASSWD:ALL 規則刪掉：那個
// 規則原本存在是因為 charlie 一開始沒有密碼，sudo 要密碼的話根本沒東西可以
// 輸入；現在既然已經有密碼了，NOPASSWD 這個例外就該跟著撤掉，讓 charlie 的
// sudo 改回走剛剛才加進去的 sudo group 那條標準規則（Debian 預設 %sudo 這個
// group 本來就是要密碼的）。不這樣做的話，前面加 sudo group 這個動作其實完全
// 沒有意義——NOPASSWD:ALL 的範圍本來就比 sudo group 的規則更寬，不會被蓋掉，
// sudo 還是一樣不用密碼，等於白設了這組密碼，認證成功到拿到 root 之間還是
// 沒有第二層關卡。
func main() {
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "錯誤：請用 sudo 執行這支程式（例如：sudo ~/bootstrap-sudo）")
		os.Exit(1)
	}

	var password string
	var confirm string

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewNote().
				Title("幫 " + targetUser + " 開一條救援退路").
				Description(targetUser + " 平常只能用 SSH 金鑰登入、沒有密碼。這裡幫它設一個密碼、加進 sudo group，\n這樣 WireGuard／SSH 掛掉的時候，還能從 ESXi 的 VM console 直接登入救援。"),
			huh.NewInput().
				Title("設定密碼").
				EchoMode(huh.EchoModePassword).
				Value(&password).
				Validate(func(s string) error {
					if len(s) < 8 {
						return fmt.Errorf("密碼至少要 8 個字元")
					}
					return nil
				}),
			huh.NewInput().
				Title("再輸入一次確認").
				EchoMode(huh.EchoModePassword).
				Value(&confirm),
		),
	)

	if err := form.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "表單已取消或發生錯誤：%v\n", err)
		os.Exit(1)
	}

	if password != confirm {
		fmt.Fprintln(os.Stderr, "錯誤：兩次輸入的密碼不一樣，沒有做任何變更")
		os.Exit(1)
	}

	if err := runCommand("usermod", "-aG", "sudo", targetUser); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：把 %s 加進 sudo group 失敗：%v\n", targetUser, err)
		os.Exit(1)
	}

	if err := setPassword(targetUser, password); err != nil {
		fmt.Fprintf(os.Stderr, "錯誤：設定密碼失敗：%v\n", err)
		os.Exit(1)
	}

	if err := removeNopasswdOverride(targetUser); err != nil {
		fmt.Fprintf(os.Stderr, "警告：刪除 /etc/sudoers.d/%s 失敗，sudo 目前可能還是不用密碼，請自己手動刪掉那個檔案：%v\n", targetUser, err)
	}

	fmt.Printf("%s 已經加進 sudo group、也設好密碼了，sudo 現在改成要密碼。WireGuard／SSH\n", targetUser)
	fmt.Println("都連不上的時候，可以直接從 ESXi 的 VM console 登入救援。")

	selfDelete()
}

func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func setPassword(user, password string) error {
	cmd := exec.Command("chpasswd")
	cmd.Stdin = strings.NewReader(user + ":" + password + "\n")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// 刪掉 preseed 裝機時寫的 /etc/sudoers.d/<user>（NOPASSWD:ALL）整個檔案
// ——那個檔案存在的唯一理由是 charlie 一開始沒有密碼，現在密碼已經設好
// 了，這個例外就沒有存在的必要。這個檔案是 late_command 自己唯一寫過的
// 東西，裝機之後預期不會有人手動加過其他規則進去，所以直接整檔刪掉，不
// 另外做逐行比對、改寫、visudo 驗證那一套。檔案本來就不存在（例如這支
// 腳本被跑過兩次）也不算錯誤，直接當作已經處理過。
func removeNopasswdOverride(user string) error {
	path := "/etc/sudoers.d/" + user
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// 跑完就自刪——這是一次性救援腳本，不是常駐工具，留著只會變成一個不用密碼
// 就能直接幫任何人加密碼、加 sudo 的後門。在 Linux 上刪除自己正在執行的
// 檔案是安全的：inode 在程序結束前都還在，只是從目錄裡拿掉名字而已。
func selfDelete() {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "警告：找不到自己的執行檔路徑，沒有自動刪除：%v\n", err)
		return
	}
	if err := os.Remove(exe); err != nil {
		fmt.Fprintf(os.Stderr, "警告：自我刪除失敗，手動刪掉 %s 比較安全：%v\n", exe, err)
	}
}
