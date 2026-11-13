#!/usr/bin/env bash
# 8인 부하 점검: 호스트 1 + 자동 조작 클라이언트 7. 설비 504개 공장과 적 10마리를 띄운 채
# 클라이언트들이 걷고, 쏘고, 짓고, 부순다. 도중에 한 명을 강제로 끊는다.
#   tools/load_test.sh [godot 실행 파일]
# 통과 조건: 남은 7개 프로세스의 상태 해시 일치, 재동기화 0회, 호스트가 끊긴 사람을 정리,
#            호스트 업로드가 클라이언트당 50KB/s 이하(Blueprint/04 성능 예산).
set -uo pipefail
GODOT="${1:-godot}"
PORT=$((25000 + RANDOM % 900))
OUT="$(mktemp -d)"
cd "$(dirname "$0")/.."

timeout 150 "$GODOT" --headless -- --host --port="$PORT" --name=host --saveroot="user://load_$PORT" --loadtest=host >"$OUT/host.log" 2>&1 &
sleep 2
pids=()
for i in 1 2 3 4 5 6 7; do
  timeout 150 "$GODOT" --headless -- --join=127.0.0.1 --port="$PORT" --name="bot$i" --loadtest=bot >"$OUT/bot$i.log" 2>&1 &
  pids+=($!)
  sleep 0.4
done
sleep 14
# 7번을 인사 없이 끊는다(프로세스 강제 종료).
pkill -9 -f -- "--name=bot7" || true
wait

fail=0
for n in host bot1 bot2 bot3 bot4 bot5 bot6; do
  line="$(grep '^LOADTEST' "$OUT/$n.log" | tail -1)"
  echo "${line:-LOADTEST $n (출력 없음)}" | sed 's/hash=\([0-9a-f]\{8\}\)[0-9a-f]*/hash=\1…/'
  grep -E "SCRIPT ERROR" "$OUT/$n.log" | head -3
done
count="$(grep -h '^LOADTEST' "$OUT"/host.log "$OUT"/bot[1-6].log | grep -c 'hash=')"
hashes="$(grep -h '^LOADTEST' "$OUT"/host.log "$OUT"/bot[1-6].log | grep -o 'hash=[0-9a-f]*' | sort -u | wc -l)"
[ "$count" = "7" ] || { echo "FAIL: 7개 프로세스 중 $count 개만 끝까지 갔다"; fail=1; }
[ "$hashes" = "1" ] || { echo "FAIL: 상태 해시가 서로 다르다"; fail=1; }
grep -h '^LOADTEST' "$OUT"/*.log | grep -q 'resyncs=[1-9]' && { echo "FAIL: 재동기화가 발생했다"; fail=1; }
grep -q 'LOADTEST host0 .*players=7 ' "$OUT/host.log" || { echo "FAIL: 호스트가 끊긴 플레이어를 정리하지 못했다"; fail=1; }
grep -q 'left_pos_saved=true' "$OUT/host.log" || { echo "FAIL: 끊긴 플레이어의 마지막 위치가 기억되지 않았다"; fail=1; }
kb="$(grep -o 'kb_per_client_s=[0-9.]*' "$OUT/host.log" | cut -d= -f2)"
awk -v kb="${kb:-999}" 'BEGIN { exit !(kb <= 50.0) }' || { echo "FAIL: 호스트 업로드 ${kb}KB/s (클라이언트당 예산 50)"; fail=1; }
[ "$fail" = "0" ] && echo "LOADTEST OK" || echo "로그: $OUT"
exit $fail
