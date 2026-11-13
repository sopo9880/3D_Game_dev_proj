#!/usr/bin/env bash
# 연결 끊김 점검: 호스트 프로세스를 인사 없이 죽였을 때 클라이언트가 멈추지 않고 월드에서 빠져나오는가.
#   tools/drop_test.sh [godot 실행 파일]
set -uo pipefail
GODOT="${1:-godot}"
PORT=$((26000 + RANDOM % 900))
OUT="$(mktemp -d)"
cd "$(dirname "$0")/.."

timeout 60 "$GODOT" --headless -- --host --port="$PORT" --name=drophost --saveroot="user://drop_$PORT" >"$OUT/host.log" 2>&1 &
sleep 2
timeout 40 "$GODOT" --headless -- --join=127.0.0.1 --port="$PORT" --name=dropclient --droptest >"$OUT/client.log" 2>&1 &
client=$!
sleep 4
pkill -9 -f -- "--name=drophost" || true
start=$(date +%s)
wait $client
code=$?
took=$(( $(date +%s) - start ))
grep '^DROPTEST' "$OUT/client.log" || echo "DROPTEST (출력 없음)"
grep -E "SCRIPT ERROR" "$OUT/client.log" | head -3
if [ "$code" = "0" ] && grep -q 'DROPTEST client left the world: host_closed' "$OUT/client.log" && [ "$took" -le 15 ]; then
  echo "DROPTEST OK (${took}초 만에 알아챔)"
  exit 0
fi
echo "FAIL: 클라이언트가 호스트의 사라짐을 15초 안에 알아채지 못했다 (종료 코드 $code, ${took}초). 로그: $OUT"
exit 1
