extends SceneTree
## 형식 1 세이브 샘플을 만든다(한 번만 실행해 tests/fixtures/ 에 커밋해 둔다).
##   godot --headless -s tools/make_fixture_v1.gd
## 형식 1은 형식 2에서 "inventories"가 없고 format 값이 1인 것과 같다.

func _initialize() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var w := SimWorld.new(db)
	load("res://tests/sim/factory_fixture.gd").build_line(w)
	for i in 500:
		w.tick()
	var d := w.to_dict()
	d.erase("inventories")
	d["format"] = 1
	var f := FileAccess.open("res://tests/fixtures/sim_format_1.bin", FileAccess.WRITE)
	f.store_buffer(var_to_bytes(d))
	f.close()
	print("wrote fixture, %d structures" % (d["structures"] as Array).size())
	quit()
