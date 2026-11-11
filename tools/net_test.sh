#!/usr/bin/env bash
# 멀티플레이 통합 점검: 호스트 1 + 클라이언트 3(처음부터, 늦게 참가, 방문자 역할)을 띄우고
# 같은 틱의 상태 해시가 모두 같은지 비교한다.
#   tools/net_test.sh [godot 실행 파일]
set -uo pipefail
GODOT="${1:-godot}"
PORT=$((24000 + RANDOM % 900))
OUT="$(mktemp -d)"
cd "$(dirname "$0")/.."

run() { # 이름, 나머지 인자
  local name="$1"; shift
  timeout 90 "$GODOT" --headless -- "$@" --port="$PORT" --name="$name" --nettest="$name" >"$OUT/$name.log" 2>&1 &
}

run host --host
sleep 1.5
run client --join=127.0.0.1
sleep 6
run late --join=127.0.0.1
sleep 2
run visitor --join=127.0.0.1
wait

fail=0
for n in host client late visitor; do
  line="$(grep '^NETTEST' "$OUT/$n.log" | tail -1)"
  echo "${line:-NETTEST $n (출력 없음)}"
  grep -E "SCRIPT ERROR|ERROR:" "$OUT/$n.log" | grep -v -i "alsa\|audio" | head -5
done
hashes="$(grep -h '^NETTEST' "$OUT"/*.log | grep -o 'hash=[0-9a-f]*' | sort -u | wc -l)"
count="$(grep -h '^NETTEST' "$OUT"/*.log | grep -c 'hash=')"
[ "$count" = "4" ] || { echo "FAIL: 4개 프로세스 중 $count 개만 결과를 냈다"; fail=1; }
[ "$hashes" = "1" ] || { echo "FAIL: 상태 해시가 서로 다르다"; fail=1; }
grep -q 'NETTEST host .*players=4 remote_seen=3' "$OUT/host.log" || { echo "FAIL: 호스트가 3명의 위치를 받지 못했다"; fail=1; }
grep -q 'NETTEST visitor .*rejected=no_permission' "$OUT/visitor.log" || { echo "FAIL: 방문자의 설치가 거절되지 않았다"; fail=1; }
grep -q 'NETTEST late .*remote_seen=[1-9]' "$OUT/late.log" || { echo "FAIL: 늦게 온 참가자가 다른 플레이어를 보지 못했다"; fail=1; }
grep -h '^NETTEST' "$OUT"/*.log | grep -q 'resyncs=[1-9]' && { echo "FAIL: 재동기화가 발생했다(결정론이 깨짐)"; fail=1; }
[ "$fail" = "0" ] && echo "NETTEST OK" || { echo "로그: $OUT"; }
exit $fail
