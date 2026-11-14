extends TestCase

const ROOT := "user://test_worlds"

var db: ContentDB
var store: SaveStore


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	store = SaveStore.new(ROOT)
	for m in store.list_worlds():
		store.delete(m["world_id"])
	for d in DirAccess.get_directories_at(ROOT):
		store._remove_dir(ROOT.path_join(d))


func _world(ticks: int) -> SimWorld:
	var w := SimWorld.new(db)
	w.ensure_player("ann")
	FactoryFixture.build_line(w)
	w.place(&"floor", Vector3i(40, 0, 0))
	w.place_free(&"lamp", Vector3i(41000, 200, 1500), 90, "ann")
	var p := w.place(&"plot", Vector3i(50, 0, 0), 0, "ann")
	w.plant("ann", p.id, &"glowleaf_seed")
	FactoryFixture.run(w, ticks)
	return w


func test_write_then_read_gives_same_world() -> void:
	var w := _world(300)
	check(store.write("w1", "테스트 월드", {"sim": w.to_dict(), "players": {"ann": [1.0, 2.0, 3.0, 0.5]}}, w.tick_count), store.last_error)
	var data := store.read("w1")
	check(not data.is_empty(), "읽기: " + store.last_error)
	var loaded := SimWorld.from_dict(db, SaveMigrations.migrate_sim(data["sim"]))
	check(loaded != null, "시뮬레이션 복원")
	eq(loaded.state_hash(), w.state_hash(), "저장 전과 같은 상태")
	eq(data["players"], {"ann": [1.0, 2.0, 3.0, 0.5]}, "플레이어 위치")
	var m := store.read_manifest("w1")
	eq(m["name"], "테스트 월드", "이름")
	eq(int(m["play_ticks"]), 300, "플레이 틱")
	eq(int(m["save_version"]), SaveStore.SAVE_VERSION, "파일 버전")


func test_list_is_sorted_by_recent() -> void:
	store.write("a", "A", {"sim": {}, "x": 1}, 0)
	store.write("b", "B", {"sim": {}, "x": 1}, 0)
	var ids: Array = store.list_worlds().map(func(m: Dictionary) -> String: return m["world_id"])
	check(ids.has("a") and ids.has("b"), "두 월드 모두 보임")
	eq(ids.size(), 2, "임시·백업 폴더는 목록에 나오지 않음")


func test_each_save_keeps_previous_as_backup_up_to_five() -> void:
	for i in 8:
		check(store.write("w", "W", {"n": i}, i), store.last_error)
	eq(store.read("w")["n"], 7, "최신 저장")
	eq(store.backup_count("w"), SaveStore.MAX_BACKUPS, "백업은 5개까지")


func test_corrupt_main_save_falls_back_to_backup() -> void:
	store.write("w", "W", {"n": 1}, 0)
	store.write("w", "W", {"n": 2}, 0)
	# 본 저장의 데이터를 망가뜨린다.
	var f := FileAccess.open(ROOT.path_join("w/world.bin"), FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	var data := store.read("w")
	eq(data.get("n", -1), 1, "백업에서 복구")
	check(store.last_error != "", "복구했음을 알린다")


func test_crash_between_swap_steps_is_recovered() -> void:
	store.write("w", "W", {"n": 1}, 0)
	store.write("w", "W", {"n": 2}, 0)
	# 기존을 백업으로 옮긴 직후 꺼진 상황: 본 폴더가 없고 임시 폴더가 온전하다.
	DirAccess.rename_absolute(ROOT.path_join("w"), ROOT.path_join("w.tmp"))
	eq(store.read("w").get("n", -1), 2, "임시 폴더를 새 저장으로 승격")
	# 본 폴더도 임시 폴더도 없는 상황: 최근 백업을 되살린다.
	store._remove_dir(ROOT.path_join("w"))
	eq(store.read("w").get("n", -1), 1, "백업을 되살림")


func test_leftover_partial_tmp_is_discarded() -> void:
	store.write("w", "W", {"n": 1}, 0)
	DirAccess.make_dir_recursive_absolute(ROOT.path_join("w.tmp"))
	var f := FileAccess.open(ROOT.path_join("w.tmp/world.bin"), FileAccess.WRITE)
	f.store_string("half")
	f.close()
	eq(store.read("w").get("n", -1), 1, "쓰다 만 저장은 무시")
	check(not DirAccess.dir_exists_absolute(ROOT.path_join("w.tmp")), "임시 폴더 정리")
	check(store.write("w", "W", {"n": 2}, 0), "그 뒤에도 저장 가능")


func test_newer_file_version_is_refused() -> void:
	store.write("w", "W", {"n": 1}, 0)
	var path := ROOT.path_join("w/manifest.json")
	var m: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	m["save_version"] = SaveStore.SAVE_VERSION + 1
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(m))
	f.close()
	check(store.read("w").is_empty(), "더 새 버전의 세이브는 열지 않는다")
	check(store.last_error.contains("새로운"), "이유를 알려 준다: " + store.last_error)


func test_missing_world_reads_empty() -> void:
	check(store.read("nope").is_empty())
	check(store.read_manifest("nope").is_empty())


## 형식 1(v0.2.x, 소지품이 없던 때)의 세이브를 지금 형식으로 올려 불러온다.
func test_format_1_fixture_migrates_and_runs() -> void:
	var old: Variant = bytes_to_var(FileAccess.get_file_as_bytes("res://tests/fixtures/sim_format_1.bin"))
	check(old is Dictionary and int((old as Dictionary).get("format", 0)) == 1, "형식 1 샘플")
	var migrated := SaveMigrations.migrate_sim(old)
	eq(int(migrated.get("format", 0)), SimWorld.SAVE_FORMAT, "현재 형식으로 올라감")
	var w := SimWorld.from_dict(db, migrated)
	check(w != null, "불러오기")
	eq(w.structures.size(), 13, "구조물 13개(기준 라인)")
	eq(w.tick_count, 500, "틱")
	var storage := w.storages[0]
	var before := w.count_in(storage.id, &"iron_ingot")
	FactoryFixture.run(w, 600)
	eq(w.count_in(storage.id, &"iron_ingot") - before, 60, "불러온 공장이 계속 분당 60개를 만든다")
	check(w.ensure_player("ann"), "옛 세이브의 플레이어는 처음 접속할 때 시작 지급품을 받는다")


func test_unknown_or_future_sim_format_is_rejected() -> void:
	check(SaveMigrations.migrate_sim({"format": 99}).is_empty(), "미래 형식")
	check(SaveMigrations.migrate_sim({}).is_empty(), "형식 표시 없음")


## 형식 2(v0.3.0, 건축 구역이 없던 때)의 세이브도 그대로 불러온다.
func test_format_2_fixture_migrates_with_everything_intact() -> void:
	var old: Variant = bytes_to_var(FileAccess.get_file_as_bytes("res://tests/fixtures/sim_format_2.bin"))
	check(old is Dictionary and int((old as Dictionary).get("format", 0)) == 2, "형식 2 샘플")
	var w := SimWorld.from_dict(db, SaveMigrations.migrate_sim(old))
	check(w != null, "불러오기")
	eq(w.structures.size(), 18, "구조물 18개")
	eq(w.inv_count("ann", db.item_index(&"glowleaf_seed")), 3, "소지품")
	eq(w.decor_count, 1, "장식")
	check(w.plates.has(Vector3i(40, 4, 0)), "2층 바닥")
	eq(w.plot_state(w.plots[0]), "growing", "자라던 작물")
	check(w.build_zones.is_empty(), "구역이 없으면 전체가 평지")
	eq(w.can_place(&"storage", Vector3i(100, 0, 100), 0), "", "어디든 지을 수 있다")


## 형식 3(v0.3.x, 구역 복원이 없던 때)의 세이브도 그대로 불러온다.
func test_format_3_fixture_migrates_with_zones_intact() -> void:
	var old: Variant = bytes_to_var(FileAccess.get_file_as_bytes("res://tests/fixtures/sim_format_3.bin"))
	check(old is Dictionary and int((old as Dictionary).get("format", 0)) == 3, "형식 3 샘플")
	var w := SimWorld.from_dict(db, SaveMigrations.migrate_sim(old))
	check(w != null, "불러오기")
	eq(w.structures.size(), 19, "구조물 19개")
	eq(w.build_zones.size(), 2, "건축 구역 2개")
	eq(w.ground_y(101, 1), 3, "높은 단")
	check(w.occupancy.has(Vector3i(102, 3, 2)), "단 위의 저장소")
	eq(w.zone_progress(0), 0, "복원은 처음부터")
	check(not w.boss_defeated(0), "우두머리는 살아 있다")


## 형식 4(v0.5.1, 연구가 없던 때)의 세이브: 지어 둔 설비는 그대로 돌고, 연구는 처음부터다.
func test_format_4_fixture_keeps_built_machines_and_starts_research_fresh() -> void:
	var old: Variant = bytes_to_var(FileAccess.get_file_as_bytes("res://tests/fixtures/sim_format_4.bin"))
	check(old is Dictionary and int((old as Dictionary).get("format", 0)) == 4, "형식 4 샘플")
	var w := SimWorld.from_dict(db, SaveMigrations.migrate_sim(old))
	check(w != null, "불러오기")
	eq(w.structures.size(), 22, "구조물 22개")
	eq(w.batteries.size(), 1, "축전지")
	eq(w.harvesters.size(), 1, "수확기")
	eq(w.zone_progress(0), 40, "복원 진행도")
	check(w.boss_defeated(0), "우두머리 처치 기록")
	check(not w.structure_unlocked(db.structures[&"wind_turbine"]), "연구는 처음부터")
	FactoryFixture.run(w, 20)
	check(w.batteries[0].grid != null, "지어 둔 풍력과 축전지는 계속 돈다")
