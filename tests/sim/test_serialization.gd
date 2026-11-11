extends TestCase


func test_round_trip_preserves_state_and_future() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var a := SimWorld.new(db)
	FactoryFixture.build_line(a)
	FactoryFixture.build_line(a, Vector3i(40, 0, 0))
	FactoryFixture.run(a, 437)

	# 저장 파일과 같은 경로: 기본형만 담은 사전 → 바이트 → 사전.
	var bytes := var_to_bytes(a.to_dict())
	var b := SimWorld.from_dict(db, bytes_to_var(bytes))
	check(b != null, "불러오기")
	eq(b.to_dict(), a.to_dict(), "불러온 직후 상태")

	# 같은 상태에서 같은 틱 수를 돌리면 결과도 같아야 한다(결정론).
	FactoryFixture.run(a, 900)
	FactoryFixture.run(b, 900)
	eq(b.to_dict(), a.to_dict(), "900틱 뒤 상태")


func test_two_fresh_worlds_stay_identical() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var a := SimWorld.new(db)
	var b := SimWorld.new(db)
	FactoryFixture.build_line(a)
	FactoryFixture.build_line(b)
	FactoryFixture.run(a, 1234)
	FactoryFixture.run(b, 1234)
	eq(a.to_dict(), b.to_dict(), "두 월드의 상태")


func test_rejects_unknown_format() -> void:
	var db := ContentDB.load_from_dir("res://data")
	eq(SimWorld.from_dict(db, {"format": 999}), null, "모르는 형식")
