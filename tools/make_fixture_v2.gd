extends SceneTree
## 형식 2 세이브 샘플을 만든다(형식 3으로 올리기 직전에 한 번 실행해 커밋해 둔 것).
##   godot --headless -s tools/make_fixture_v2.gd

func _initialize() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var w := SimWorld.new(db)
	w.ensure_player("ann")
	load("res://tests/sim/factory_fixture.gd").build_line(w)
	w.place(&"wall", Vector3i(40, 0, 0), 0, "ann")
	w.place(&"floor", Vector3i(40, 4, 0), 0, "ann")
	w.place(&"storage", Vector3i(40, 4, 0), 0, "ann")
	w.place_free(&"lamp", Vector3i(41000, 4200, 1500), 90, "ann")
	var p := w.place(&"plot", Vector3i(50, 0, 0), 0, "ann")
	w.plant("ann", p.id, &"glowleaf_seed")
	for i in 500:
		w.tick()
	var d := w.to_dict()
	assert(int(d["format"]) == 2)
	var f := FileAccess.open("res://tests/fixtures/sim_format_2.bin", FileAccess.WRITE)
	f.store_buffer(var_to_bytes(d))
	f.close()
	print("wrote format-2 fixture, %d structures, hash %s" % [(d["structures"] as Array).size(), w.state_hash()])
	quit()
