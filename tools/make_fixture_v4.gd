extends SceneTree
## 형식 4 세이브 샘플을 만든다(형식 5로 올리기 직전에 한 번 실행해 커밋해 둔 것).
##   godot --headless -s tools/make_fixture_v4.gd

func _initialize() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var w := SimWorld.new(db)
	w.add_build_zone(-10, 0, 80, 40, 0)
	w.add_build_zone(100, 0, 20, 20, 3)
	w.ensure_player("ann")
	w.place(&"storage", Vector3i(102, 3, 2), 0, "ann")
	load("res://tests/sim/factory_fixture.gd").build_line(w)
	w.place(&"wall", Vector3i(40, 0, 0), 0, "ann")
	w.place(&"floor", Vector3i(40, 4, 0), 0, "ann")
	w.place(&"storage", Vector3i(40, 4, 0), 0, "ann")
	w.place_free(&"lamp", Vector3i(41000, 4200, 1500), 90, "ann")
	var p := w.place(&"plot", Vector3i(50, 0, 0), 0, "ann")
	w.plant("ann", p.id, &"glowleaf_seed")
	w.place(&"wind_turbine", Vector3i(60, 0, 0), 0, "ann")
	w.place(&"battery", Vector3i(63, 0, 0), 0, "ann")
	w.place(&"harvester", Vector3i(53, 0, 0), 0, "ann")
	w.restore[0] = 40
	w.set_boss_defeated(0)
	for i in 500:
		w.tick()
	var d := w.to_dict()
	assert(int(d["format"]) == 4)
	var f := FileAccess.open("res://tests/fixtures/sim_format_4.bin", FileAccess.WRITE)
	f.store_buffer(var_to_bytes(d))
	f.close()
	print("wrote format-4 fixture, %d structures, hash %s" % [(d["structures"] as Array).size(), w.state_hash()])
	quit()
