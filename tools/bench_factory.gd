extends SceneTree
## 공장 시뮬레이션 벤치마크 (Blueprint/04 성능 예산 확인용).
##   godot --headless -s tools/bench_factory.gd [-- --units=870 --budget-ms=2.0]
## 기준 생산 라인을 격자로 깔고 틱 시간을 잰다. 평균이 예산을 넘으면 종료 코드 1.

const FactoryFixtureScript := preload("res://tests/sim/factory_fixture.gd")


func _initialize() -> void:
	var units := 870
	var budget_ms := 2.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--units="):
			units = int(a.trim_prefix("--units="))
		elif a.begins_with("--budget-ms="):
			budget_ms = float(a.trim_prefix("--budget-ms="))

	var db := ContentDB.load_from_dir("res://data")
	var w := SimWorld.new(db)
	var side := ceili(sqrt(float(units)))
	var t0 := Time.get_ticks_usec()
	for i in units:
		FactoryFixtureScript.build_line(w, Vector3i((i % side) * 16, 0, (i / side) * 24))
	var build_ms := (Time.get_ticks_usec() - t0) / 1000.0

	var belt_cells := 0
	for b in w.belts:
		belt_cells += b.cells.size()
	var machines := w.structures.size() - w.belts.size()

	t0 = Time.get_ticks_usec()
	w.tick()  # 토폴로지 재계산 포함
	var topo_ms := (Time.get_ticks_usec() - t0) / 1000.0
	for i in 499:
		w.tick()

	w.profile.fill(0)
	var samples := PackedInt64Array()
	for i in 1000:
		var t := Time.get_ticks_usec()
		w.tick()
		samples.append(Time.get_ticks_usec() - t)
	samples.sort()
	var sum := 0
	for s in samples:
		sum += s
	var avg_ms := sum / 1000.0 / samples.size()

	var ingots := 0
	for st in w.storages:
		ingots += st.store.get(db.item_index(&"iron_ingot"), 0)

	print("설비 %d개, 벨트 %d줄 / %d칸, 전력망 %d개" % [machines, w.belts.size(), belt_cells, w.grids.size()])
	print("설치 %.0f ms, 토폴로지 재계산 %.0f ms" % [build_ms, topo_ms])
	print("틱 시간: 평균 %.3f ms, 중앙 %.3f ms, p99 %.3f ms, 최대 %.3f ms" % [
		avg_ms, samples[500] / 1000.0, samples[989] / 1000.0, samples[999] / 1000.0])
	print("단계별 평균(ms): 준비 %.3f, 전력 %.3f, 진행 %.3f, 벨트 %.3f, 출력 %.3f" % [
		w.profile[0] / 1e6, w.profile[1] / 1e6, w.profile[2] / 1e6, w.profile[3] / 1e6, w.profile[4] / 1e6])
	print("1500틱 뒤 저장된 주괴 %d개 (라인당 %.1f개)" % [ingots, float(ingots) / units])
	print("예산 %.1f ms: %s" % [budget_ms, "통과" if avg_ms <= budget_ms else "초과"])
	quit(0 if avg_ms <= budget_ms else 1)
