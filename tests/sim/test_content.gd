extends TestCase


func test_content_loads_without_errors() -> void:
	var db := ContentDB.load_from_dir("res://data")
	eq(Array(db.errors), [], "콘텐츠 오류")
	check(db.items.size() >= 12, "아이템 12종 이상")
	check(db.structures.has(&"miner") and db.structures.has(&"belt"))


func test_recipes_are_attached_to_machines() -> void:
	var db := ContentDB.load_from_dir("res://data")
	eq(db.structures[&"smelter"].recipes.size(), 1, "제련기 레시피 수")
	eq(db.structures[&"assembler"].recipes.size(), 3, "조립기 레시피 수")


func test_content_hash_is_stable() -> void:
	var a := ContentDB.load_from_dir("res://data")
	var b := ContentDB.load_from_dir("res://data")
	eq(a.content_hash(), b.content_hash(), "해시")
	check(a.content_hash().length() == 64)


## Blueprint/05 "수치 검산" 표를 데이터로 확인한다.
func test_slice_numbers_balance() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var mine := db.recipes[&"mine_iron_ore"]
	var smelt := db.recipes[&"smelt_iron"]
	var miner_per_min := 600 * mine.out_count / mine.ticks
	var smelter_per_min := 600 * smelt.in_counts[0] / smelt.ticks
	eq(miner_per_min, 60, "채굴기 분당 생산")
	eq(smelter_per_min * 2, miner_per_min, "제련기 2대 = 채굴기 1대")
	var belt_per_min := 600 / int(db.structures[&"belt"].params["period"])
	eq(belt_per_min, 120, "벨트 분당 운반")
	var demand := db.structures[&"miner"].power_use + 2 * db.structures[&"smelter"].power_use
	var gen := db.structures[&"bio_generator"]
	eq(demand, 40, "기준 라인 전력 수요")
	check(demand <= gen.power_gen, "발전기 1대로 기준 라인 가동")
	check(demand + db.structures[&"assembler"].power_use > gen.power_gen, "조립기를 더하면 전력 부족")
	eq(gen.fuels[db.item_index(&"biofuel")], 300, "연료 1개 연소 틱")
