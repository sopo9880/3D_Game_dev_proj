extends TestCase

var db: ContentDB
var w: SimWorld
var zone: ZoneDef


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	zone = db.zone_by_id(&"blighted_hollow")
	w.ensure_player("ann")
	# 비콘 자리만 건축할 수 있는 작은 터, 그리고 정원.
	w.add_build_zone(zone.beacon_site.x - 2, zone.beacon_site.z - 2, 7, 7, 0)
	w.add_build_zone(0, 0, 40, 40, 0)


func test_zone_data_is_valid() -> void:
	check(zone != null, "구역 정의")
	eq(zone.capsule_points, 10, "캡슐 하나의 진행도")
	eq(db.items[db.item_ids[zone.capsule_item]].id, &"purifier_capsule", "캡슐 아이템")


func test_beacon_only_on_its_site() -> void:
	eq(w.can_place(&"beacon", Vector3i(5, 0, 5), 0), "needs_site", "정원의 비콘")
	eq(w.can_place(&"beacon", zone.beacon_site, 0), "", "비콘 자리")
	var b := w.place(&"beacon", zone.beacon_site)
	check(b != null and b.zone == zone.index, "비콘이 구역에 묶임")
	eq(w.beacon_of(zone.index), b, "구역의 비콘 찾기")


func test_ten_capsules_restore_the_zone_and_unlock_building() -> void:
	var b := w.place(&"beacon", zone.beacon_site)
	var inside := Vector3i(zone.unlock_zone[0] + 10, 0, zone.unlock_zone[1] + 10)
	eq(w.can_place(&"storage", inside, 0), "not_buildable", "복원 전에는 골짜기에 지을 수 없다")
	w.inv_add("ann", zone.capsule_item, 12)
	eq(w.insert_from("ann", b.id, &"purifier_capsule", 3), 3, "캡슐 3개")
	eq(w.zone_progress(zone.index), 30, "진행도 30")
	check(not w.zone_restored(zone.index))
	eq(w.insert_from("ann", b.id, &"purifier_capsule", 99), 7, "100이 되면 더 받지 않는다")
	eq(w.zone_progress(zone.index), 100, "복원 완료")
	eq(w.inv_count("ann", zone.capsule_item), 2, "남은 캡슐은 소지품에")
	eq(w.can_place(&"storage", inside, 0), "", "복원 뒤에는 골짜기에 지을 수 있다")
	eq(w.insert_from("ann", b.id, &"iron_ingot", 5), 0, "캡슐이 아닌 것은 받지 않는다")


func test_capsules_arrive_by_belt() -> void:
	var b := w.place(&"beacon", zone.beacon_site)
	# 비콘의 입력 포트: 칸 (1,0,2)의 남쪽. 저장소에서 벨트로 캡슐을 보낸다.
	var attach := zone.beacon_site + Vector3i(1, 0, 3)
	w.add_build_zone(attach.x - 3, attach.z, 8, 12, 0)
	var chest := w.place(&"storage", attach + Vector3i(0, 0, 4))
	check(chest != null, "저장소")
	var path: Array[Vector3i] = [attach + Vector3i(0, 0, 3), attach + Vector3i(0, 0, 2), attach + Vector3i(0, 0, 1), attach]
	check(w.place_belt(&"belt", path) != null, "벨트")
	w.insert(chest.id, &"purifier_capsule", 10)
	for i in 400:
		w.tick()
	eq(b.def.port_cells.size(), 1, "비콘 입력 포트")
	eq(w.zone_progress(zone.index), 100, "벨트로 보낸 캡슐 10개로 복원")


func test_boss_flag_and_progress_survive_save() -> void:
	var b := w.place(&"beacon", zone.beacon_site)
	w.inv_add("ann", zone.capsule_item, 4)
	w.insert_from("ann", b.id, &"purifier_capsule", 4)
	w.set_boss_defeated(zone.index)
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	check(loaded != null)
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.zone_progress(zone.index), 40, "진행도")
	check(loaded.boss_defeated(zone.index), "우두머리 처치 기록")
	check(loaded.beacon_of(zone.index) != null, "비콘")


func test_restored_zone_stays_buildable_after_load() -> void:
	var b := w.place(&"beacon", zone.beacon_site)
	w.inv_add("ann", zone.capsule_item, 10)
	w.insert_from("ann", b.id, &"purifier_capsule", 10)
	var inside := Vector3i(zone.unlock_zone[0] + 10, 0, zone.unlock_zone[1] + 10)
	check(w.place(&"storage", inside) != null)
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.can_place(&"storage", inside + Vector3i(5, 0, 5), 0), "", "불러온 뒤에도 건축 가능")


func test_hand_gathering_has_cooldown_per_node() -> void:
	var ore_cell := Vector3i(3, 0, 3)
	var crystal_cell := Vector3i(8, 0, 8)
	w.add_node(ore_cell, &"iron_ore")
	w.add_node(crystal_cell, &"taint_crystal")
	eq(w.gather("ann", ore_cell), db.item_index(&"iron_ore"), "광석 캐기")
	eq(w.gather("ann", ore_cell), -1, "바로 다시는 못 캔다")
	eq(w.gather("ann", crystal_cell), db.item_index(&"taint_crystal"), "다른 자리는 따로")
	for i in 10:
		w.tick()
	eq(w.gather("ann", ore_cell), db.item_index(&"iron_ore"), "1초 뒤 광석")
	eq(w.gather("ann", crystal_cell), -1, "결정은 5초")
	for i in 40:
		w.tick()
	eq(w.gather("ann", crystal_cell), db.item_index(&"taint_crystal"), "5초 뒤 결정")
	eq(w.inv_count("ann", db.item_index(&"iron_ore")), 2, "광석 2개")
	eq(w.gather("ann", Vector3i(20, 0, 20)), -1, "아무것도 없는 자리")
	eq(w.gather("nobody", ore_cell), -1, "없는 플레이어")


func test_miner_cannot_sit_on_crystal_node() -> void:
	w.add_node(Vector3i(11, 0, 11), &"taint_crystal")
	eq(w.can_place(&"miner", Vector3i(10, 0, 10), 0), "needs_node", "결정 덩어리 위의 채굴기")


## 버티컬 슬라이스의 복원 재료 계산 (Blueprint/05 수치 검산).
func test_restoration_material_budget() -> void:
	var capsule := db.recipes[&"make_capsule"]
	var capsules_needed := 100 / zone.capsule_points
	eq(capsules_needed, 10, "캡슐 10개")
	var crystals := 0
	var leaves := 0
	for i in capsule.in_items.size():
		if db.item_ids[capsule.in_items[i]] == &"taint_crystal":
			crystals = capsule.in_counts[i] * capsules_needed
		elif db.item_ids[capsule.in_items[i]] == &"glowleaf":
			leaves = capsule.in_counts[i] * capsules_needed
	eq(crystals, 10, "오염 결정 10")
	eq(leaves, 20, "빛잎 20")
