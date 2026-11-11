extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)


func test_floor_on_ground_and_machine_on_floor() -> void:
	check(w.place(&"floor", Vector3i(0, 0, 0)) != null, "지면에 바닥")
	eq(w.can_place(&"floor", Vector3i(2, 0, 2), 0), "occupied", "겹치는 바닥")
	# 바닥판은 칸을 차지하지 않으므로 그 위에 설비를 놓을 수 있다.
	check(w.place(&"smelter", Vector3i(0, 0, 0)) != null, "바닥 위의 설비")


func test_upper_floor_needs_support() -> void:
	eq(w.can_place(&"floor", Vector3i(0, 4, 0), 0), "no_support", "허공의 바닥")
	check(w.place(&"wall", Vector3i(0, 0, 0), 0) != null, "지면의 벽")
	eq(w.can_place(&"floor", Vector3i(0, 4, 0), 0), "", "벽 위의 바닥")
	check(w.place(&"floor", Vector3i(0, 4, 0)) != null)
	eq(w.can_place(&"floor", Vector3i(4, 4, 0), 0), "", "이웃한 바닥에 이어 붙이기")
	eq(w.can_place(&"floor", Vector3i(12, 4, 0), 0), "no_support", "떨어진 곳")
	# 2층 바닥 위에 설비와 벽.
	eq(w.can_place(&"smelter", Vector3i(0, 4, 0), 0), "", "2층의 설비")
	eq(w.can_place(&"smelter", Vector3i(8, 4, 0), 0), "no_support", "바닥이 없는 2층")
	eq(w.can_place(&"wall", Vector3i(0, 4, 0), 1), "", "2층 바닥 위의 벽")
	eq(w.can_place(&"wall", Vector3i(20, 4, 0), 0), "no_support", "허공의 벽")


func test_walls_share_edges_and_stack() -> void:
	check(w.place(&"wall", Vector3i(0, 0, 0), 0) != null)
	eq(w.can_place(&"wall", Vector3i(2, 0, 0), 0), "occupied", "같은 모서리")
	eq(w.can_place(&"wall", Vector3i(0, 0, 0), 1), "", "모퉁이에서 직각으로")
	eq(w.can_place(&"wall", Vector3i(0, 4, 0), 0), "", "벽 위의 벽")
	# 벽은 칸을 막지 않는다(얇다).
	eq(w.can_place(&"storage", Vector3i(0, 0, 0), 0), "", "벽 옆 칸의 설비")


func test_stairs_occupy_cells_and_support_floor_above() -> void:
	check(w.place(&"stairs", Vector3i(0, 0, 0)) != null, "계단")
	eq(w.can_place(&"storage", Vector3i(1, 0, 1), 0), "occupied", "계단 안")
	eq(w.can_place(&"floor", Vector3i(0, 4, 0), 0), "", "계단 꼭대기의 바닥")


func test_removed_support_does_not_collapse_and_reload_keeps_everything() -> void:
	var wall := w.place(&"wall", Vector3i(0, 0, 0), 0)
	var floor2 := w.place(&"floor", Vector3i(0, 4, 0))
	check(w.place(&"storage", Vector3i(0, 4, 0)) != null)
	w.remove(wall.id)
	check(w.structures.has(floor2.id), "받침을 철거해도 위층은 남는다")
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	check(loaded != null)
	eq(loaded.to_dict(), w.to_dict(), "받침 없이 떠 있는 구조물도 그대로 불러온다")


func test_height_limit() -> void:
	eq(w.can_place(&"floor", Vector3i(0, -4, 0), 0), "out_of_bounds", "지하")
	eq(w.can_place(&"floor", Vector3i(0, 400, 0), 0), "out_of_bounds", "너무 높음")


func test_decor_is_free_placed_and_round_trips() -> void:
	eq(w.can_place(&"chair", Vector3i.ZERO, 0), "use_place_free", "장식은 격자 설치가 아니다")
	var s := w.place_free(&"chair", Vector3i(1250, 0, -730), 395)
	check(s != null)
	eq(s.free_yaw, 35, "방향은 0..359로 정리")
	check(w.place(&"storage", Vector3i(1, 0, -1)) != null, "장식은 칸을 차지하지 않는다")
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.decor_count, 1, "장식 수")
	w.remove(s.id)
	eq(w.decor_count, 0, "철거 후 장식 수")


func test_belt_needs_support_on_upper_floors() -> void:
	eq(w.can_place_belt([Vector3i(0, 4, 0), Vector3i(1, 4, 0)]), "no_support", "허공의 벨트")
	w.place(&"wall", Vector3i(0, 0, 0), 0)
	w.place(&"floor", Vector3i(0, 4, 0))
	eq(w.can_place_belt([Vector3i(0, 4, 0), Vector3i(1, 4, 0)]), "", "2층 바닥 위의 벨트")


func test_port_dir_lookup_for_belt_snapping() -> void:
	w.place(&"smelter", Vector3i(0, 0, 0))
	# 제련기 출력 포트: 칸 (0,0,0)의 북쪽 → 바깥 칸 (0,0,-1). 입력 포트: (0,0,2)의 남쪽 → (0,0,3).
	eq(w.port_dir_at(Vector3i(0, 0, -1), true), 0, "출력 포트 방향")
	eq(w.port_dir_at(Vector3i(0, 0, 3), false), 2, "입력 포트 방향")
	eq(w.port_dir_at(Vector3i(0, 0, -1), false), -1, "출력 자리에서 입력을 찾으면 없음")
	eq(w.port_dir_at(Vector3i(5, 0, 5), true), -1, "아무것도 없는 칸")
