extends TestCase

var db: ContentDB
var w: SimWorld
var ingot: int
var seed_item: int
var leaf: int


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	ingot = db.item_index(&"iron_ingot")
	seed_item = db.item_index(&"glowleaf_seed")
	leaf = db.item_index(&"glowleaf")


func test_new_player_gets_starting_kit_once() -> void:
	check(w.ensure_player("ann"), "처음")
	eq(w.inv_count("ann", ingot), 40, "시작 주괴")
	eq(w.inv_count("ann", seed_item), 4, "시작 씨앗")
	w.inv_remove("ann", ingot, 10)
	check(not w.ensure_player("ann"), "두 번째는 지급하지 않음")
	eq(w.inv_count("ann", ingot), 30, "그대로")


func test_inventory_add_remove() -> void:
	w.ensure_player("ann")
	eq(w.inv_remove("ann", ingot, 100), 40, "있는 만큼만 뺀다")
	eq(w.inv_count("ann", ingot), 0, "빈 항목")
	check(not (w.inventories["ann"] as Dictionary).has(ingot), "0개 항목은 지운다")
	w.inv_add("nobody", ingot, 5)
	eq(w.inv_count("nobody", ingot), 0, "없는 플레이어")


func test_build_cost_pay_and_full_refund() -> void:
	w.ensure_player("ann")
	var def := db.structures[&"smelter"]
	var cost := w.build_cost(def)
	eq(cost, {ingot: 10} as Dictionary[int, int], "제련기 비용")
	check(w.can_afford("ann", cost))
	w.pay("ann", cost)
	var s := w.place(&"smelter", Vector3i.ZERO, 0, "ann")
	eq(w.inv_count("ann", ingot), 30, "지불 후")
	w.inv_add_all("ann", w.refund_of(s))
	w.remove(s.id)
	eq(w.inv_count("ann", ingot), 40, "철거 시 전액 환급")


func test_belt_cost_scales_with_length() -> void:
	var def := db.structures[&"belt"]
	eq(w.build_cost(def, 1)[ingot], 1, "1칸")
	eq(w.build_cost(def, 4)[ingot], 1, "4칸")
	eq(w.build_cost(def, 5)[ingot], 2, "5칸")
	eq(w.build_cost(def, 23)[ingot], 6, "23칸")


func test_cannot_afford_expensive_structure() -> void:
	w.ensure_player("ann")
	check(not w.can_afford("ann", w.build_cost(db.structures[&"assembler"])), "정밀 부품이 없다")


func test_insert_from_and_take_to_inventory() -> void:
	w.ensure_player("ann")
	w.inv_add("ann", db.item_index(&"iron_ore"), 3)
	var gen := w.place(&"bio_generator", Vector3i(5, 0, 0))
	var s := w.place(&"smelter", Vector3i.ZERO)
	w.inv_add("ann", db.item_index(&"biofuel"), 1)
	eq(w.insert_from("ann", gen.id, &"biofuel", 5), 1, "가진 만큼만 넣는다")
	eq(w.insert_from("ann", s.id, &"iron_ore", 10), 3, "가진 광석 3개")
	eq(w.inv_count("ann", db.item_index(&"iron_ore")), 0, "소지품에서 빠짐")
	for i in 100:
		w.tick()
	eq(w.take_to("ann", s.id, &"iron_ingot", 99), 3, "주괴 3개 꺼내기")
	eq(w.inv_count("ann", ingot), 43, "소지품에 들어옴")


func test_hand_crafting_at_workbench() -> void:
	w.ensure_player("ann")
	eq(w.craft("ann", &"make_rifle_ammo", 2), 2, "탄약 2회")
	eq(w.inv_count("ann", ingot), 38, "주괴 2개 사용")
	eq(w.inv_count("ann", db.item_index(&"rifle_ammo")), 150 + 60, "탄약 60발 추가")
	eq(w.craft("ann", &"make_biofuel", 5), 0, "빛잎이 없으면 못 만든다")
	w.inv_add("ann", leaf, 5)
	eq(w.craft("ann", &"make_biofuel", 5), 2, "재료가 되는 만큼만")
	eq(w.craft("ann", &"smelt_iron", 1), 0, "작업대 레시피가 아니다")


func test_plot_grows_and_harvest_matches_blueprint() -> void:
	w.ensure_player("ann")
	var p := w.place(&"plot", Vector3i.ZERO)
	eq(w.plot_state(p), "empty", "빈 밭")
	check(w.plant("ann", p.id, &"glowleaf_seed"), "심기")
	eq(w.inv_count("ann", seed_item), 3, "씨앗 1개 사용")
	check(not w.plant("ann", p.id, &"glowleaf_seed"), "이미 심은 밭")
	for i in 1199:
		w.tick()
	eq(w.plot_state(p), "growing", "1199틱")
	eq(w.harvest("ann", p.id).size(), 0, "덜 자란 작물은 못 거둔다")
	w.tick()
	eq(w.plot_state(p), "ready", "1200틱(2분)에 수확 가능")
	var got := w.harvest("ann", p.id)
	eq(got[leaf], 4, "빛잎 4개")
	check(got[seed_item] >= 1 and got[seed_item] <= 2, "씨앗 1~2개")
	eq(w.inv_count("ann", leaf), 4, "소지품에 들어옴")
	eq(w.plot_state(p), "empty", "수확 후 빈 밭")


func test_watering_halves_growth_time() -> void:
	w.ensure_player("ann")
	var p := w.place(&"plot", Vector3i.ZERO)
	w.plant("ann", p.id, &"glowleaf_seed")
	var ticks := 0
	while w.plot_state(p) != "ready" and ticks < 5000:
		w.water(p.id)   # 단계가 바뀔 때마다 다시 준다
		w.tick()
		ticks += 1
	eq(ticks, 600, "계속 물을 주면 절반 시간")
	check(not w.water(p.id), "다 자란 밭에는 물을 줄 수 없다")


func test_removing_plot_returns_seed() -> void:
	w.ensure_player("ann")
	var p := w.place(&"plot", Vector3i.ZERO)
	w.plant("ann", p.id, &"glowleaf_seed")
	var contents: Dictionary = w.remove(p.id)
	eq(contents.get(seed_item, 0), 1, "자라던 작물은 씨앗으로 돌려준다")


func test_inventories_and_plots_survive_save_and_stay_deterministic() -> void:
	w.ensure_player("ann")
	w.ensure_player("bob")
	w.inv_remove("bob", ingot, 7)
	var p := w.place(&"plot", Vector3i.ZERO, 0, "ann")
	w.plant("ann", p.id, &"glowleaf_seed")
	w.water(p.id)
	for i in 333:
		w.tick()
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	check(loaded != null)
	eq(loaded.to_dict(), w.to_dict(), "불러온 직후")
	eq(loaded.inv_count("bob", ingot), 33, "소지품")
	for i in 1000:
		w.tick()
		loaded.tick()
	loaded.harvest("ann", p.id)
	w.harvest("ann", p.id)
	eq(loaded.state_hash(), w.state_hash(), "1000틱과 수확 뒤에도 같은 상태")
