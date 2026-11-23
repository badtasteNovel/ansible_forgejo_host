#!/bin/bash
set -euo pipefail

# 處理 Harbor：本機裝一份，或接一個已經存在的外部 Harbor。INSTALL_HARBOR/
# HARBOR_URL/HARBOR_USERNAME/HARBOR_PASSWORD 這四個環境變數由 apply.sh 設好
# 才呼叫這支——這支不重新剖析表單 JSON，呼叫端已經做過這件事、也已經確認
# 欄位填好了。
#
# apply.sh 是用 source（不是直接執行）讀這支，跟 source config.sh 同一個
# 道理：source 進去只是「定義」harbor_setup 這個函式，不會自己跑，要呼叫端
# 自己明確呼叫 harbor_setup 才會真的執行——跟 config.sh 的慣例一致（source
# 永遠只是載入定義，不會有副作用）。
#
# harbor_setup 裡設的 harbor_registry/harbor_username/harbor_password 這幾個
# 變數，函式跑完之後直接留在呼叫端的變數空間裡（bash 函式預設跟呼叫端共用
# 作用域，除非變數宣告成 local），不需要透過 stdout 或任何檔案傳回去：沒有
# 人在「接」這支腳本的輸出，所以底下隨便 echo 到哪裡都沒關係，不會污染任何
# 東西（跟子行程執行、靠 $(...) 接最後一行輸出的做法不一樣，那種做法只要
# 哪一行 echo 忘記送 stderr，就會把值弄錯）。

# shellcheck source=/srv/ansible/config.sh
source /srv/ansible/config.sh

# 先宣告成空字串，純粹是給人看的文件（標示 harbor_setup 會設這個變數），
# 不影響行為——跟 apply.sh 開頭那行一樣，重複宣告不會衝突，函式裡沒加
# local 的賦值一定會蓋過這裡。
harbor_registry=""

harbor_setup() {
  if [ "$INSTALL_HARBOR" = "true" ]; then
    echo "==> 開始在本機安裝 Harbor（ansible-navigator run harbor-install.yml）..."

    # /home/harbor、/home/caddy-proxy 兩個目錄已經在 apply.sh 裡集中建好了
    # （ansible-navigator.yml 的 volume-mounts 是共用設定，驗證的是清單裡
    # 全部的來源路徑，不只是這次用到的那一個），這裡不用再處理。

    run_navigator "$HARBOR_PLAYBOOK"

    # HARBOR_HOSTNAME 是 bootstrap-services 表單問出來的（預設值直接讀
    # /srv/harbor/harbor.yml 的 hostname 欄位——裝機時就烘焙好的真實值，
    # 固定是 "harbor.internal"、不帶 vm_name，使用者可以直接接受或改掉，
    # 見 main.go 的 readHarborHostnameDefault() 說明），由 apply.sh 設成
    # 環境變數傳進來，這支不重新問、不重新算。
    harbor_registry="${HARBOR_HOSTNAME}:${CADDY_PROXY_HTTPS_PORT}"

    cp "$LOCAL_HARBOR_CA_PATH" "$LOCAL_CA_TRUST_PATH"
    update-ca-certificates

    harbor_username="robot\$$(cat "$HARBOR_SECRETS_DIR/robot-name")"
    harbor_password=$(cat "$HARBOR_SECRETS_DIR/robot-secret")
  else
    if [ -z "$HARBOR_URL" ] || [ -z "$HARBOR_USERNAME" ] || [ -z "$HARBOR_PASSWORD" ]; then
      echo "錯誤：外部 Harbor 的網址/帳密沒填完整" >&2
      exit 1
    fi
    harbor_registry="$HARBOR_URL"
    harbor_username="$HARBOR_USERNAME"
    harbor_password="$HARBOR_PASSWORD"

    echo "==> 抓外部 Harbor 的 CA 憑證並信任它（第一次抓的當下系統還不認得對方的 CA，本來就沒辦法驗證，用 -k 是先有雞還是先有蛋的必要例外）..."
    curl -ksS "https://${harbor_registry}/api/v2.0/systeminfo/getcert" -o "$EXTERNAL_CA_TRUST_PATH"
    update-ca-certificates
  fi

  echo "==> podman login ${harbor_registry}..."
  printf '%s' "$harbor_password" | podman login --authfile "$MIRROR_AUTH_FILE" --username "$harbor_username" --password-stdin "$harbor_registry"
  chmod 644 "$MIRROR_AUTH_FILE"

  # 把 proxy_map.json 的每一條上游對照，寫成 registries.conf.d 的 mirror 設定
  # ——寫完之後，任何 rootless 使用者 podman pull docker.io/... 之類的指令，
  # podman 自己會先試這裡設定的 mirror，有快取就不用再打上游。這是系統層級
  # 的設定，對所有使用者一視同仁，不管連的是本機裝的 Harbor 還是外部既有
  # 的，project 命名假設一致。
  echo "==> 已確認登入 ${harbor_registry}，寫 registries.conf.d mirror 設定..."
  mkdir -p "$(dirname "$MIRROR_CONF_PATH")"
  {
    echo "# 由 harbor.sh 自動產生，對應 $PROXY_MAP_PATH"
    jq -c '.[]' "$PROXY_MAP_PATH" | while read -r entry; do
      registry_host=$(jq -r '.registry_host' <<<"$entry")
      project=$(jq -r '.project' <<<"$entry")
      printf '[[registry]]\nlocation = "%s"\n\n[[registry.mirror]]\n  location = "%s/%s"\n\n' \
        "$registry_host" "$harbor_registry" "$project"
    done
  } >"$MIRROR_CONF_PATH"

  # 不 echo 任何東西出去——harbor_registry 這個變數就是這個函式要「回傳」的
  # 結果，呼叫端（apply.sh）呼叫完 harbor_setup 之後，自己的作用域裡就直接
  # 看得到它。
}
