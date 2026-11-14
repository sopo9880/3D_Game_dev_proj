extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	w.ensure_player("ann")
	w.ensure_player("bob")


func test_tech_data_links_structures_and_recipes() -> void:
	var solar := db.tech_by_id(&"solar_power")
	check(solar != null, "태양광 연구")
	eq(db.structures[&"solar_panel"].unlock_tech, solar.index, "태양광 패널은 태양광 연구로 열린다")
	eq(db.structures[&"smelter"].unlock_tech, -1, "제련기는 처음부터")
	eq(db.recipes[&"make_ext_mag"].unlock_tech, db.tech_by_id(&"weapon_mods").index, "확장 탄창 레시피")
	eq(db.tech_by_id(&"wind_power").requires, solar.index, "풍력은 태양광 다음")


func test_everything_in_the_vertical_slice_is_unlocked_from_the_start() -> void:
	for id: StringName in [&"floor", &"wall", &"stairs", &"miner", &"smelter", &"assembler", &"belt", &"junction",
			&"storage", &"bio_generator", &"power_pole", &"workbench", &"plot", &"beacon"]:
		check(w.structure_unlocked(db.structures[id]), "%s 는 연구 없이 지을 수 있어야 한다" % id)
	for id: StringName in [&"make_biofuel", &"make_part", &"make_capsule", &"make_rifle_ammo", &"smelt_iron"]:
		check(w.recipe_unlocked(db.recipes[id]), "%s 는 연구 없이 만들 수 있어야 한다" % id)


func test_research_costs_materials_and_unlocks_for_everyone() -> void:
	var solar := db.structures[&"solar_panel"]
	check(not w.structure_unlocked(solar), "연구 전에는 잠김")
	eq(w.can_research("ann", &"solar_power"), "cannot_afford", "재료 부족")
	w.inv_add("ann", db.item_index(&"precision_part"), 5)
	w.inv_add("ann", db.item_index(&"scrap"), 4)
	eq(w.can_research("ann", &"solar_power"), "", "재료가 있으면 가능")
	check(w.research("ann", &"solar_power"), "연구")
	eq(w.inv_count("ann", db.item_index(&"precision_part")), 1, "정밀 부품 4개 사용")
	check(w.structure_unlocked(solar), "연구 뒤 열림")
	eq(w.can_research("bob", &"solar_power"), "already_done", "월드 전체가 공유한다")
	check(not w.research("ann", &"solar_power"), "두 번 연구할 수 없다")


func test_prerequisite_and_unknown() -> void:
	w.inv_add("ann", db.item_index(&"precision_part"), 20)
	w.inv_add("ann", db.item_index(&"relic_blueprint"), 2)
	eq(w.can_research("ann", &"wind_power"), "needs_prerequisite", "선행 연구")
	eq(w.can_research("ann", &"nope"), "not_found", "없는 연구")
	w.inv_add("ann", db.item_index(&"scrap"), 4)
	w.research("ann", &"solar_power")
	eq(w.can_research("ann", &"wind_power"), "", "선행 연구 뒤에는 가능")


func test_locked_recipe_cannot_be_crafted() -> void:
	w.inv_add("ann", db.item_index(&"precision_part"), 3)
	eq(w.craft("ann", &"make_ext_mag", 1), 0, "연구 전에는 못 만든다")
	w.inv_add("ann", db.item_index(&"scrap"), 6)
	w.inv_add("ann", db.item_index(&"relic_blueprint"), 1)
	check(w.research("ann", &"weapon_mods"), "무기 개조 연구")
	eq(w.craft("ann", &"make_ext_mag", 1), 1, "연구 뒤에는 만든다")


func test_research_survives_save() -> void:
	w.inv_add("ann", db.item_index(&"precision_part"), 4)
	w.inv_add("ann", db.item_index(&"scrap"), 4)
	w.research("ann", &"solar_power")
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	check(loaded.structure_unlocked(db.structures[&"solar_panel"]), "불러온 뒤에도 열려 있다")
	check(not loaded.structure_unlocked(db.structures[&"wind_turbine"]), "연구하지 않은 것은 잠겨 있다")


## 연구 재료가 게임 안에서 실제로 구해지는 것들인가.
func test_tech_costs_use_obtainable_items() -> void:
	var obtainable: Dictionary[int, bool] = {}
	for rid: StringName in db.recipes:
		obtainable[db.recipes[rid].out_item] = true
	for c in db.crops:
		obtainable[c.product_item] = true
	for e in EnemyDef.load_all("res://data/enemies.json"):
		for row: Array in e.loot:
			obtainable[db.item_index(StringName(str(row[0])))] = true
	for item: int in db.gather_ticks:
		obtainable[item] = true
	for t in db.techs:
		for item in t.cost_items:
			check(obtainable.has(item), "연구 %s 의 재료 %s 를 얻을 방법이 없다" % [t.id, db.item_ids[item]])
