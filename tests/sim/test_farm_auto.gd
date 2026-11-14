extends TestCase

var db: ContentDB
var w: SimWorld
var leaf: int


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	w.ensure_player("ann")
	leaf = db.item_index(&"glowleaf")
	w.inv_add("ann", db.item_index(&"glowleaf_seed"), 20)
	w.place(&"wind_turbine", Vector3i(10, 0, 10))   # 전력


func _run(ticks: int) -> void:
	for i in ticks:
		w.tick()


func _planted(cell: Vector3i) -> SimStructure:
	var p := w.place(&"plot", cell)
	w.plant("ann", p.id, &"glowleaf_seed")
	return p


func test_sprinkler_keeps_plots_watered() -> void:
	var p := _planted(Vector3i(0, 0, 0))
	var far := _planted(Vector3i(0, 0, 20))
	check(w.place(&"sprinkler", Vector3i(3, 0, 0)) != null, "관수기 설치")
	var ticks := 0
	while w.plot_state(p) != "ready" and ticks < 3000:
		w.tick()
		ticks += 1
	eq(ticks, 600, "관수기가 닿는 밭은 절반 시간에 자란다")
	eq(w.plot_state(far), "growing", "닿지 않는 밭은 그대로")


func test_sprinkler_needs_power() -> void:
	var w2 := SimWorld.new(db)
	w2.ensure_player("ann")
	var p := w2.place(&"plot", Vector3i(0, 0, 0))
	w2.plant("ann", p.id, &"glowleaf_seed")
	w2.place(&"sprinkler", Vector3i(3, 0, 0))
	for i in 50:
		w2.tick()
	check(not p.watered, "전력이 없으면 물을 주지 않는다")
	eq(p.growth, 50, "보통 속도로 자란다")


func test_harvester_collects_and_replants() -> void:
	var p := _planted(Vector3i(0, 0, 0))
	var h := w.place(&"harvester", Vector3i(3, 0, 0))
	check(h != null, "수확기 설치")
	_run(1201)
	eq(h.out_count, 4, "빛잎 4개를 거뒀다")
	eq(h.out_item, leaf, "거둔 것은 빛잎")
	eq(w.plot_state(p), "growing", "같은 작물이 다시 자란다(씨앗을 쓰지 않는다)")
	eq(w.inv_count("ann", db.item_index(&"glowleaf_seed")), 23, "씨앗은 처음 심을 때 한 개만 썼다")
	eq(w.take_to("ann", h.id, &"glowleaf", 99), 4, "손으로 꺼내기")
	eq(w.inv_count("ann", leaf), 4, "소지품에 들어옴")


func test_harvester_stops_when_full() -> void:
	var plots: Array[SimStructure] = []
	for i in 8:
		plots.append(_planted(Vector3i(i % 4 * 2 - 4, 0, i / 4 * 2)))
	var h := w.place(&"harvester", Vector3i(0, 0, 4))
	for p in plots:
		p.growth = 1200
	_run(2)
	eq(h.out_count, 24, "버퍼 24에서 멈춘다(6곳만 거둠)")
	var waiting := 0
	for p in plots:
		if w.plot_state(p) == "ready":
			waiting += 1
	eq(waiting, 2, "나머지 두 곳은 거두지 않고 기다린다")


## 농장이 벨트로 공장에 이어진다: 수확기 → 벨트 → 조립기(바이오 연료).
func test_farm_feeds_factory_by_belt() -> void:
	_planted(Vector3i(0, 0, 0)).growth = 1195
	_planted(Vector3i(2, 0, 0)).growth = 1195
	# 수확기의 출력 포트: 칸 (4,0,0)의 북쪽 → 바깥 칸 (4,0,-1).
	var h := w.place(&"harvester", Vector3i(4, 0, 0))
	# 조립기의 입력 포트 바깥 칸: 원점 + (0,0,3). 조립기를 (4,0,-8)에 두면 (4,0,-5).
	var a := w.place(&"assembler", Vector3i(4, 0, -8))
	check(w.set_recipe(a.id, &"make_biofuel") != null, "조립기 레시피")
	var path: Array[Vector3i] = []
	for z in range(-1, -6, -1):
		path.append(Vector3i(4, 0, z))
	check(w.place_belt(&"belt", path) != null, "벨트")
	_run(400)
	check(h.out_lines.size() == 1, "수확기 출력이 벨트에 연결")
	eq(a.produced_total, 4, "빛잎 8개 → 바이오 연료 4개")


func test_harvester_state_survives_save() -> void:
	_planted(Vector3i(0, 0, 0)).growth = 1199
	w.place(&"harvester", Vector3i(3, 0, 0))
	w.place(&"sprinkler", Vector3i(0, 0, 3))
	_run(5)
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.harvesters[0].out_count, 4, "거둔 작물")
	for i in 700:
		w.tick()
		loaded.tick()
	eq(loaded.state_hash(), w.state_hash(), "이후에도 같은 상태")
