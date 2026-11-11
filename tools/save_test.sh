#!/usr/bin/env bash
# 저장/이어하기 점검: 한 번 실행해 공장을 짓고 저장한 뒤, 새로 실행해 불러온 상태가 같은지 본다.
#   tools/save_test.sh [godot 실행 파일]
set -uo pipefail
GODOT="${1:-godot}"
ROOT="user://savetest_$RANDOM"
OUT="$(mktemp -d)"
cd "$(dirname "$0")/.."

timeout 90 "$GODOT" --headless -- --single --name=tester --saveroot="$ROOT" --savetest=write >"$OUT/write.log" 2>&1
w="$(grep '^SAVETEST write' "$OUT/write.log")"
id="$(echo "$w" | grep -o 'id=[0-9a-f]*' | cut -d= -f2)"
echo "${w:-SAVETEST write (출력 없음)}"
grep '^SAVETEST saved' "$OUT/write.log"
timeout 90 "$GODOT" --headless -- --single --name=tester --saveroot="$ROOT" --world="$id" --savetest=read >"$OUT/read.log" 2>&1
r="$(grep '^SAVETEST read' "$OUT/read.log")"
echo "${r:-SAVETEST read (출력 없음)}"
grep -hE "SCRIPT ERROR|ERROR:" "$OUT"/*.log | grep -v -i "alsa\|audio" | head -5

fail=0
[ -n "$id" ] || { echo "FAIL: 월드 ID를 얻지 못했다"; fail=1; }
grep -q 'SAVETEST saved=true' "$OUT/write.log" || { echo "FAIL: 저장 실패"; fail=1; }
wh="$(echo "$w" | grep -o 'tick=[0-9]* hash=[0-9a-f]* structures=[0-9]*')"
rh="$(echo "$r" | grep -o 'tick=[0-9]* hash=[0-9a-f]* structures=[0-9]*')"
[ -n "$wh" ] && [ "$wh" = "$rh" ] || { echo "FAIL: 불러온 상태가 저장한 상태와 다르다"; fail=1; }
echo "$r" | grep -q 'pos=-6.0,-5.0 yaw=1.25' || { echo "FAIL: 플레이어 위치가 복원되지 않았다"; fail=1; }
[ "$fail" = "0" ] && echo "SAVETEST OK" || echo "로그: $OUT"
exit $fail
