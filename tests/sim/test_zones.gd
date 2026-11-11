extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	w.add_build_zone(0, 0, 20, 20, 0)     # 평지 단
	w.add_build_zone(30, 0, 12, 12, 3)    # 3m 높은 단


func test_ground_height_lookup() -> void:
	eq(w.ground_y(5, 5), 0, "평지 단")
	eq(w.ground_y(31, 1), 3, "높은 단")
	eq(w.ground_y(25, 5), SimWorld.NO_GROUND, "단 사이")
	eq(SimWorld.new(db).ground_y(999, -999), 0, "구역이 없으면 어디든 0")


func test_cannot_build_outside_zones() -> void:
	eq(w.can_place(&"storage", Vector3i(24, 0, 5), 0), "not_buildable", "구역 밖 설비")
	eq(w.can_place(&"floor", Vector3i(22, 0, 0), 0), "not_buildable", "구역 밖 바닥")
	eq(w.can_place(&"floor", Vector3i(18, 0, 0), 0), "not_buildable", "구역에 걸친 바닥")
	eq(w.can_place_belt([Vector3i(19, 0, 5), Vector3i(20, 0, 5)]), "not_buildable", "구역을 벗어나는 벨트")
	eq(w.can_place_free(&"lamp", Vector3i(25000, 0, 5000)), "not_buildable", "구역 밖 장식")
	eq(w.can_place(&"wall", Vector3i(24, 0, 24), 0), "not_buildable", "구역 밖 벽")
	eq(w.can_place(&"wall", Vector3i(0, 0, 0), 0), "", "구역 가장자리의 벽은 된다")


func test_raised_terrace_uses_its_own_ground() -> void:
	eq(w.can_place(&"storage", Vector3i(32, 0, 2), 0), "out_of_bounds", "단보다 낮은 곳")
	eq(w.can_place(&"storage", Vector3i(32, 3, 2), 0), "", "단 위")
	eq(w.can_place(&"storage", Vector3i(32, 5, 2), 0), "no_support", "단 위 허공")
	check(w.place(&"floor", Vector3i(30, 3, 0)) != null, "단 위 바닥")
	check(w.place(&"wall", Vector3i(30, 3, 0), 0) != null, "단 위 벽")
	eq(w.can_place(&"floor", Vector3i(30, 7, 0), 0), "", "그 벽 위의 2층 (단 높이 + 4)")
	eq(w.can_place_free(&"lamp", Vector3i(31000, 3000, 1000)), "", "단 위 장식")
	eq(w.can_place_free(&"lamp", Vector3i(31000, 0, 1000)), "out_of_bounds", "단 속의 장식")


func test_decor_cannot_overlap_closely() -> void:
	check(w.place_free(&"chair", Vector3i(5000, 0, 5000), 0) != null)
	eq(w.can_place_free(&"chair", Vector3i(5100, 0, 5100)), "occupied", "거의 같은 자리")
	eq(w.can_place_free(&"chair", Vector3i(5600, 0, 5000)), "", "옆자리")
	w.remove(w.decors[0].id)
	eq(w.can_place_free(&"chair", Vector3i(5100, 0, 5100)), "", "치우면 다시 놓을 수 있다")


func test_zones_survive_save() -> void:
	w.place(&"storage", Vector3i(32, 3, 2))
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.ground_y(31, 1), 3, "불러온 뒤 단 높이")
