extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)


func test_step_direction() -> void:
	eq(SimWorld.belt_step_dir(Vector3i(0, 0, 0), Vector3i(0, 0, -1)), 0, "북")
	eq(SimWorld.belt_step_dir(Vector3i(0, 0, 0), Vector3i(1, 1, 0)), 1, "동으로 한 칸 오르기")
	eq(SimWorld.belt_step_dir(Vector3i(0, 3, 0), Vector3i(0, 2, 1)), 2, "남으로 한 칸 내리기")
	eq(SimWorld.belt_step_dir(Vector3i(0, 0, 0), Vector3i(0, 1, 0)), -1, "수직으로만은 안 된다")
	eq(SimWorld.belt_step_dir(Vector3i(0, 0, 0), Vector3i(1, 2, 0)), -1, "한 번에 두 칸 높이는 안 된다")
	eq(SimWorld.belt_step_dir(Vector3i(0, 0, 0), Vector3i(1, 0, 1)), -1, "대각선은 안 된다")


func test_slope_is_self_supporting_but_flat_air_is_not() -> void:
	var ramp: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 1, 0), Vector3i(2, 2, 0), Vector3i(3, 3, 0)]
	eq(w.can_place_belt(ramp), "", "지면에서 시작하는 경사")
	var ramp_then_flat: Array[Vector3i] = ramp.duplicate()
	ramp_then_flat.append(Vector3i(4, 4, 0))
	ramp_then_flat.append(Vector3i(5, 4, 0))
	ramp_then_flat.append(Vector3i(6, 4, 0))
	eq(w.can_place_belt(ramp_then_flat), "no_support", "경사 끝의 평평한 구간은 바닥이 있어야 한다")
	w.place(&"wall", Vector3i(4, 0, 0), 1)
	w.place(&"floor", Vector3i(4, 4, 0))
	eq(w.can_place_belt(ramp_then_flat), "", "2층 바닥 위로 이어지면 된다")


## 1층의 저장소에서 2층의 저장소로 경사 벨트가 물건을 올린다.
func test_slope_carries_items_between_floors() -> void:
	w.place(&"wall", Vector3i(8, 0, 0), 1)
	w.place(&"floor", Vector3i(8, 4, 0))
	var low := w.place(&"storage", Vector3i(0, 0, 0), 1)     # 동쪽을 보게 돌림: 출력이 +X
	# 돌린 저장소(rot 1): 출력 포트 칸 (0,0,0) 방향 동 → 바깥 칸 (1,0,0).
	var path: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(3, 0, 0), Vector3i(4, 0, 0)]
	for i in 4:
		path.append(Vector3i(5 + i, 1 + i, 0))                # (5,1) (6,2) (7,3) (8,4)
	path.append(Vector3i(9, 4, 0))
	check(w.place_belt(&"belt", path) != null, "경사 벨트 설치: %s" % w.can_place_belt(path))
	# 2층 저장소: 입력 포트가 서쪽을 보게(rot 1이면 입력은 로컬 남 → 서). 입력 바깥 칸이 (9,4,0)이 되도록.
	var high := w.place(&"storage", Vector3i(11, 4, 0), 1)
	check(high != null, "2층 저장소: %s" % w.can_place(&"storage", Vector3i(11, 4, 0), 1))
	w.insert(low.id, &"iron_ore", 30)
	for i in 600:
		w.tick()
	eq(w.count_in(high.id, &"iron_ore"), 30, "30개가 모두 2층으로 올라갔다")


func test_fast_belt_carries_200_per_minute() -> void:
	var a := w.place(&"storage", Vector3i(0, 0, 10))
	var b := w.place(&"storage", Vector3i(0, 0, 0))
	var path: Array[Vector3i] = []
	for z in range(9, 1, -1):
		path.append(Vector3i(0, 0, z))
	check(w.place_belt(&"belt_fast", path) != null, "고속 벨트")
	w.insert(a.id, &"iron_ore", 1000)
	for i in 200:
		w.tick()
	var before := w.count_in(b.id, &"iron_ore")
	for i in 600:
		w.tick()
	eq(w.count_in(b.id, &"iron_ore") - before, 200, "1분간 200개(3틱마다 한 칸)")
	eq(w.build_cost(db.structures[&"belt_fast"], 8)[db.item_index(&"iron_ingot")], 4, "8칸 비용 = 주괴 4")


func test_sloped_belt_survives_save() -> void:
	var ramp: Array[Vector3i] = [Vector3i(0, 0, 0), Vector3i(1, 1, 0), Vector3i(2, 2, 0)]
	w.place_belt(&"belt", ramp)
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	check(loaded != null)
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.belts[0].cells.size(), 3, "칸 수")
