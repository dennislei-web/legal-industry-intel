#!/usr/bin/env bash
# 爬蟲 workflow 收尾用：依序打 PostgREST 的無參數 refresh RPC；清單一定跑完，最後才決定紅綠燈。
#   用法：bash .github/scripts/refresh-rpcs.sh <rpc> [<rpc> ...]
#   環境：SUPABASE_URL、SUPABASE_SERVICE_KEY
#
# 回應分類（與 scripts/judgment_stats.py 的 _call_rpc 同一套）：
#   2xx                         OK
#   5xx／連線錯誤／408／409／429  暫時性：隔 60 秒重試，最多 3 次（剛跑完大量寫入，Supabase 可能還忙；
#                               409 多半是前一次逾時的呼叫還在伺服器端跑、兩次撞鍵，等它結束再打就會過）
#   其餘 4xx                     確定性錯誤（函數壞了、PGRST202 找不到函數、權限不足…）：重試也不會好，不重試
#
# 結果：
#   最後停在 4xx          → ::error::，清單內其他 RPC 照跑，全部跑完後 exit 1（job 紅燈）
#   5xx／連線錯誤重試耗盡  → ::warning::，不紅燈
# 4xx 別改回 warning——它不會「下次重刷就好」：refresh_firm_map_cache 曾天天回 400、job 照樣綠燈，
# firm_map_default_cache 停更一個月才被發現（mig 237）。

MAX_ATTEMPTS=3
RETRY_WAIT=60  # 秒

if [ "$#" -eq 0 ]; then
  echo "::error::refresh-rpcs.sh：沒有指定要刷新的 RPC"
  exit 1
fi

# secrets 可能帶尾端空白/換行，會讓 PostgREST 回 400 PGRST102（curl 不像 Python 會 strip）
SUPABASE_URL="$(printf %s "${SUPABASE_URL:-}" | tr -d '[:space:]')"
SUPABASE_SERVICE_KEY="$(printf %s "${SUPABASE_SERVICE_KEY:-}" | tr -d '[:space:]')"
if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_SERVICE_KEY" ]; then
  echo "::error::refresh-rpcs.sh：SUPABASE_URL／SUPABASE_SERVICE_KEY 沒有設定"
  exit 1
fi

resp="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$resp" "$err"' EXIT

# 非 2xx 的說明：回應本文前 300 bytes（PostgREST 的錯誤 JSON；閘道回的 HTML 頁不印）；
# curl 自己失敗時沒有回應本文，改用它的錯誤訊息
failure_detail() {
  local src="$resp" text
  [ "$http_code" = 000 ] && src="$err"
  text="$(head -c 300 "$src")"
  text="${text//$'\r'/}"
  text="${text//$'\n'/ }"  # 併成一行，才放得進 ::error::／::warning::
  case "$text" in '<'*) text='' ;; esac
  printf '%s' "$text"
}

failed=()   # 最後停在 4xx → 紅燈
gave_up=()  # 5xx／連線錯誤重試耗盡 → 只警告

for rpc in "$@"; do
  ok=0
  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    : > "$resp"
    # curl 自己失敗（逾時、連不上）就沒有可信的 HTTP 狀態碼，一律記成 000
    http_code="$(curl -sS -k -o "$resp" -w '%{http_code}' --max-time 180 \
      -X POST "$SUPABASE_URL/rest/v1/rpc/${rpc}" \
      -H "apikey: $SUPABASE_SERVICE_KEY" \
      -H "Authorization: Bearer $SUPABASE_SERVICE_KEY" \
      -H "Content-Type: application/json" -d '{}' 2>"$err")" || http_code=000
    echo "${rpc} attempt ${attempt}: HTTP ${http_code}"
    case "$http_code" in
      2??)
        echo "  ✅ OK"
        ok=1
        break ;;
      5??|000|408|409|429)
        detail="$(failure_detail)"
        [ -n "$detail" ] && echo "  $detail"
        if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
          echo "  retrying in ${RETRY_WAIT}s..."
          sleep "$RETRY_WAIT"
        fi ;;
      *)
        detail="$(failure_detail)"
        [ -n "$detail" ] && echo "  $detail"
        break ;;
    esac
  done
  [ "$ok" -eq 1 ] && continue

  case "$http_code" in
    5??|000)
      echo "::warning::${rpc} 重試 ${MAX_ATTEMPTS} 次仍失敗（HTTP ${http_code}），這次沒刷新${detail:+：${detail}}"
      gave_up+=("$rpc") ;;
    *)
      echo "::error::${rpc} 回 HTTP ${http_code}，沒刷新（4xx 不會自己好，要修函數或設定）${detail:+：${detail}}"
      failed+=("$rpc") ;;
  esac
done

echo
echo "=== 刷新結果：共 $# 支，4xx 失敗 ${#failed[@]} 支，重試耗盡 ${#gave_up[@]} 支 ==="
if [ "${#gave_up[@]}" -gt 0 ]; then
  echo "重試耗盡（只警告）：${gave_up[*]}"
fi
if [ "${#failed[@]}" -gt 0 ]; then
  echo "4xx 失敗（紅燈）：${failed[*]}"
  exit 1
fi
exit 0
