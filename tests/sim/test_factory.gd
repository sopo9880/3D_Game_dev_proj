extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)


func _all_placed(r: Dictionary) -> bool:
	for k: String in r:
		if r[k] == null:
			return false
	for b: Variant in r["belts"]:
		if b == null:
			return false
	return true


func test_reference_line_builds() -> void:
	var r := FactoryFixture.build_line(w)
	check(_all_placed(r), "기준 라인의 모든 구조물이 설치됨")
	w.tick()
	eq((r["miner"] as SimStructure).out_lines.size(), 1, "채굴기 출력 연결")
	eq((r["split"] as SimStructure).out_lines.size(), 2, "분배기 출력 2개")
	eq((r["merge"] as SimStructure).out_lines.size(), 1, "합류기 출력 1개")
	for b: SimStructure in r["belts"]:
		check(b.dst != null, "벨트 %d 의 도착지" % b.id)
	check((r["smelter_a"] as SimStructure).grid != null, "제련기 전력망")
	eq(w.grids.size(), 1, "전력망 수")


## 채굴기 1 + 분배기 + 제련기 2: 정상 상태에서 600틱(1분) 동안 주괴가 정확히 60개 늘어난다.
func test_reference_line_makes_60_ingots_per_minute() -> void:
	var r := FactoryFixture.build_line(w)
	var storage: SimStructure = r["storage"]
	FactoryFixture.run(w, 400)
	var before := w.count_in(storage.id, &"iron_ingot")
	check(before > 0, "예열 뒤 주괴가 도착해 있음")
	FactoryFixture.run(w, 600)
	eq(w.count_in(storage.id, &"iron_ingot") - before, 60, "1분간 주괴")
	eq((r["smelter_a"] as SimStructure).state, SimStructure.State.RUNNING, "제련기 A 상태")
	eq((r["smelter_b"] as SimStructure).state, SimStructure.State.RUNNING, "제련기 B 상태")
	eq(w.grids[0].ratio, 1000, "전력 충족률")


func test_splitter_alternates_evenly() -> void:
	var r := FactoryFixture.build_line(w)
	FactoryFixture.run(w, 1000)
	var a: SimStructure = r["smelter_a"]
	var b: SimStructure = r["smelter_b"]
	check(absi(a.produced_total - b.produced_total) <= 1, "두 제련기 생산량 차이 %d / %d" % [a.produced_total, b.produced_total])


func test_no_fuel_means_no_power() -> void:
	var r := FactoryFixture.build_line(w, Vector3i.ZERO, 0)
	FactoryFixture.run(w, 100)
	eq((r["miner"] as SimStructure).state, SimStructure.State.NO_POWER, "채굴기 상태")
	eq((r["miner"] as SimStructure).produced_total, 0, "생산량")


func test_generator_burns_fuel_only_under_demand() -> void:
	var gen := w.place(&"bio_generator", Vector3i.ZERO)
	w.insert(gen.id, &"biofuel", 3)
	FactoryFixture.run(w, 500)
	eq(gen.fuel_count, 3, "수요가 없으면 연료를 쓰지 않는다")


func test_fuel_lasts_300_ticks_each() -> void:
	var r := FactoryFixture.build_line(w, Vector3i.ZERO, 2)
	var gen: SimStructure = r["gen"]
	FactoryFixture.run(w, 600)
	eq(gen.fuel_count, 0, "연료 2개 = 600틱")
	eq(gen.burn_left, 0, "연소 끝")
	FactoryFixture.run(w, 50)
	eq((r["miner"] as SimStructure).state, SimStructure.State.NO_POWER, "연료가 떨어지면 정지")


## 수요 60 / 공급 50: 멈추지 않고 비례해서 느려진다.
func test_power_shortage_slows_down_proportionally() -> void:
	var r := FactoryFixture.build_line(w)
	# 같은 전력망에 채굴기 2대(각각 저장소로 연결)를 더 올려 수요를 60으로 만든다.
	var extra: Array[SimStructure] = []
	for x: int in [12, 16]:
		w.add_node(Vector3i(x + 1, 0, 21), &"iron_ore")
		extra.append(w.place(&"miner", Vector3i(x, 0, 20)))
		check(w.place(&"storage", Vector3i(x + 1, 0, 14)) != null, "추가 저장소")
		var path: Array[Vector3i] = []
		for z in range(19, 15, -1):
			path.append(Vector3i(x + 1, 0, z))
		check(w.place_belt(&"belt", path) != null, "추가 벨트")
	check(extra[0] != null and extra[1] != null, "추가 채굴기 설치")
	FactoryFixture.run(w, 300)
	eq(w.grids[0].demand, 60, "수요")
	eq(w.grids[0].supply, 50, "공급")
	eq(w.grids[0].ratio, 833, "충족률 천분율")
	eq((r["miner"] as SimStructure).state, SimStructure.State.RUNNING, "느려져도 가동 중")
	# 600틱 동안 채굴기는 60개가 아니라 그 83%(50개)쯤을 캔다. 제련기가 쉬는 틱에는 수요가 줄어 조금 더 나올 수 있다.
	var before := extra[0].produced_total
	FactoryFixture.run(w, 600)
	var mined := extra[0].produced_total - before
	check(mined >= 49 and mined <= 53, "전력 부족 시 채굴량 %d" % mined)


func test_output_blocks_when_storage_is_full() -> void:
	var r := FactoryFixture.build_line(w)
	var storage: SimStructure = r["storage"]
	# 저장소를 다른 아이템으로 꽉 채운다 (24칸 × 100개).
	eq(w.insert(storage.id, &"scrap", 5000), 2400, "저장소 용량")
	FactoryFixture.run(w, 1500)
	eq(w.count_in(storage.id, &"iron_ingot"), 0, "가득 찬 저장소에는 들어가지 않는다")
	eq((r["smelter_a"] as SimStructure).state, SimStructure.State.OUTPUT_BLOCKED, "제련기 출력 막힘")
	eq((r["miner"] as SimStructure).state, SimStructure.State.OUTPUT_BLOCKED, "역류 압력이 채굴기까지 전달")
	# 자리를 비우면 다시 흐른다.
	w.take(storage.id, &"scrap", 2400)
	FactoryFixture.run(w, 300)
	check(w.count_in(storage.id, &"iron_ingot") > 0, "막힘이 풀리면 다시 흐른다")


func test_belt_carries_120_per_minute() -> void:
	var a := w.place(&"storage", Vector3i(0, 0, 10))
	var b := w.place(&"storage", Vector3i(0, 0, 0))
	# a의 출력 포트는 (0,0,10) 북쪽 → 바깥 칸 (0,0,9). b의 입력 포트 바깥 칸은 (0,0,2).
	var path: Array[Vector3i] = []
	for z in range(9, 1, -1):
		path.append(Vector3i(0, 0, z))
	check(w.place_belt(&"belt", path) != null, "벨트 설치")
	w.insert(a.id, &"iron_ore", 1000)
	FactoryFixture.run(w, 200)
	var before := w.count_in(b.id, &"iron_ore")
	FactoryFixture.run(w, 600)
	eq(w.count_in(b.id, &"iron_ore") - before, 120, "1분간 운반")


func test_placement_rules() -> void:
	eq(w.can_place(&"miner", Vector3i.ZERO, 0), "needs_node", "광맥 없는 채굴기")
	check(w.place(&"smelter", Vector3i.ZERO) != null)
	eq(w.can_place(&"smelter", Vector3i(1, 0, 2), 0), "occupied", "겹침")
	eq(w.can_place(&"nope", Vector3i(50, 0, 0), 0), "unknown_structure", "없는 구조물")
	eq(w.can_place_belt([Vector3i(9, 0, 9), Vector3i(11, 0, 9)]), "not_adjacent", "끊어진 벨트")
	eq(w.can_place_belt([Vector3i(0, 0, 0), Vector3i(0, 0, -1)]), "occupied", "설비 위의 벨트")


func test_rotation_moves_ports() -> void:
	# 동쪽을 보게 돌린 제련기: 출력 포트가 +X 쪽으로 간다.
	var s := w.place(&"smelter", Vector3i(0, 0, 0), 1)
	check(s != null)
	var belt := w.place_belt(&"belt", [Vector3i(1, 0, 0), Vector3i(2, 0, 0)])
	w.tick()
	eq(s.out_lines.size(), 1, "회전한 출력 포트에 벨트 연결")
	eq(s.out_lines[0].id if s.out_lines.size() == 1 else -1, belt.id, "연결된 벨트")


func test_remove_returns_contents_and_frees_cells() -> void:
	var r := FactoryFixture.build_line(w)
	FactoryFixture.run(w, 600)
	var storage: SimStructure = r["storage"]
	var had := w.count_in(storage.id, &"iron_ingot")
	check(had > 0)
	var contents: Dictionary = w.remove(storage.id)
	eq(contents.get(db.item_index(&"iron_ingot"), 0), had, "철거 시 내용물 반환")
	eq(w.can_place(&"storage", storage.cell, 0), "", "철거한 자리는 비어 있다")
	eq(w.remove(storage.id), null, "없는 구조물 철거")
	FactoryFixture.run(w, 10)  # 연결이 끊긴 채로도 문제 없이 돈다


func test_hand_feeding_works_without_belts() -> void:
	var gen := w.place(&"bio_generator", Vector3i(5, 0, 0))
	var s := w.place(&"smelter", Vector3i.ZERO)
	w.insert(gen.id, &"biofuel", 1)
	eq(w.insert(s.id, &"iron_ore", 10), 4, "입력 버퍼 한도까지만 들어간다")
	eq(w.insert(s.id, &"scrap", 1), 0, "레시피에 없는 재료는 거절")
	FactoryFixture.run(w, 100)
	eq(w.take(s.id, &"iron_ingot", 99), 4, "손으로 꺼내기")
