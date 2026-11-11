class_name ContentDB
extends RefCounted
## 콘텐츠 정의 전체. data/*.json을 읽어 검증한다.
## 시뮬레이션은 오토로드 대신 이 객체를 생성자로 받는다.

var items: Dictionary[StringName, ItemDef] = {}
var item_ids: Array[StringName] = []  ## 인덱스 → ID
var recipes: Dictionary[StringName, RecipeDef] = {}
var structures: Dictionary[StringName, StructureDef] = {}
var crops: Array[CropDef] = []
var starting_kit: Dictionary[int, int] = {}   ## 아이템 인덱스 → 수량
var max_build_height: int = 48
var max_decor: int = 2000
var errors: PackedStringArray = []


static func load_from_dir(dir: String) -> ContentDB:
	var db := ContentDB.new()
	db._load_items(db._read(dir.path_join("items.json")))
	db._load_recipes(db._read(dir.path_join("recipes.json")))
	db._load_structures(db._read(dir.path_join("structures.json")))
	db._load_crops(db._read(dir.path_join("crops.json")))
	db._load_rules(dir.path_join("rules.json"))
	return db


func is_valid() -> bool:
	return errors.is_empty()


func item_index(id: StringName) -> int:
	var d: ItemDef = items.get(id)
	return d.index if d != null else -1


func item_def(index: int) -> ItemDef:
	return items[item_ids[index]]


## 접속 시 호스트와 클라이언트의 콘텐츠가 같은지 비교하는 값.
func content_hash() -> String:
	var parts: PackedStringArray = []
	for id in item_ids:
		parts.append(String(id))
	for id: StringName in recipes:
		var r := recipes[id]
		parts.append("%s:%s:%s:%d:%d:%d" % [id, r.in_items, r.in_counts, r.out_item, r.out_count, r.ticks])
	for id: StringName in structures:
		var s := structures[id]
		parts.append("%s:%d:%s:%d:%d:%d:%s" % [id, s.kind, s.footprint, s.power_use, s.power_gen, s.power_radius, JSON.stringify(s.params)])
	for c in crops:
		parts.append("%s:%d:%d:%d:%d:%d:%d:%d" % [c.id, c.seed_item, c.product_item, c.grow_ticks, c.stages, c.yield_count, c.seed_return, c.bonus_seed_percent])
	parts.append("kit:%s:%d:%d" % [starting_kit, max_build_height, max_decor])
	return "\n".join(parts).sha256_text()


func _read(path: String) -> Array:
	if not FileAccess.file_exists(path):
		errors.append("파일 없음: %s" % path)
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Array:
		errors.append("JSON 배열이 아님: %s" % path)
		return []
	return parsed


func _load_items(rows: Array) -> void:
	for row: Dictionary in rows:
		var d := ItemDef.new()
		d.id = StringName(str(row.get("id", "")))
		if d.id == &"" or items.has(d.id):
			errors.append("아이템 ID 누락 또는 중복: '%s'" % d.id)
			continue
		d.index = item_ids.size()
		d.display_name = str(row.get("name", d.id))
		d.stack_size = int(row.get("stack", 100))
		d.category = StringName(str(row.get("category", "material")))
		if d.stack_size <= 0:
			errors.append("아이템 %s: stack은 1 이상" % d.id)
		items[d.id] = d
		item_ids.append(d.id)


func _stack(what: String, pair: Variant) -> Vector2i:
	if not pair is Array or (pair as Array).size() != 2:
		errors.append("%s: [아이템, 수량] 형식이 아님" % what)
		return Vector2i(-1, 0)
	var arr: Array = pair
	var idx := item_index(StringName(str(arr[0])))
	if idx < 0:
		errors.append("%s: 없는 아이템 '%s'" % [what, arr[0]])
	if int(arr[1]) <= 0:
		errors.append("%s: 수량은 1 이상" % what)
	return Vector2i(idx, int(arr[1]))


func _load_recipes(rows: Array) -> void:
	for row: Dictionary in rows:
		var r := RecipeDef.new()
		r.id = StringName(str(row.get("id", "")))
		if r.id == &"" or recipes.has(r.id):
			errors.append("레시피 ID 누락 또는 중복: '%s'" % r.id)
			continue
		var what := "레시피 %s" % r.id
		for pair: Variant in row.get("inputs", []):
			var st := _stack(what, pair)
			if r.in_items.has(st.x):
				errors.append("%s: 같은 재료가 두 번 나옴" % what)
			r.in_items.append(st.x)
			r.in_counts.append(st.y)
		var out := _stack(what, row.get("output"))
		r.out_item = out.x
		r.out_count = out.y
		r.ticks = int(row.get("ticks", 0))
		if r.ticks <= 0:
			errors.append("%s: ticks는 1 이상" % what)
		for m: Variant in row.get("machines", []):
			r.machines.append(StringName(str(m)))
		r.unlocked_by_default = bool(row.get("unlocked", true))
		recipes[r.id] = r


func _load_structures(rows: Array) -> void:
	for row: Dictionary in rows:
		var s := StructureDef.new()
		s.id = StringName(str(row.get("id", "")))
		if s.id == &"" or structures.has(s.id):
			errors.append("구조물 ID 누락 또는 중복: '%s'" % s.id)
			continue
		var what := "구조물 %s" % s.id
		s.tab = StringName(str(row.get("tab", "building")))
		var kind_name := str(row.get("kind", "none"))
		if not StructureDef.KIND_NAMES.has(kind_name):
			errors.append("%s: 알 수 없는 kind '%s'" % [what, kind_name])
		s.kind = StructureDef.KIND_NAMES.get(kind_name, StructureDef.Kind.NONE)
		s.footprint = _v3(row.get("footprint", [1, 1, 1]))
		if s.footprint.x <= 0 or s.footprint.y <= 0 or s.footprint.z <= 0:
			errors.append("%s: footprint는 양수" % what)
		for pair: Variant in row.get("cost", []):
			var st := _stack(what, pair)
			s.cost_items.append(st.x)
			s.cost_counts.append(st.y)
		for p: Dictionary in row.get("ports", []):
			var cell := _v3(p.get("cell", [0, 0, 0]))
			if cell.x < 0 or cell.y < 0 or cell.z < 0 or cell.x >= s.footprint.x or cell.y >= s.footprint.y or cell.z >= s.footprint.z:
				errors.append("%s: 포트가 발자국 밖에 있음 %s" % [what, cell])
			var dir_name := str(p.get("dir", ""))
			var io_name := str(p.get("io", ""))
			if not StructureDef.DIR_NAMES.has(dir_name) or not StructureDef.IO_NAMES.has(io_name):
				errors.append("%s: 포트 dir/io 값 오류" % what)
				continue
			s.port_cells.append(cell)
			s.port_dirs.append(StructureDef.DIR_NAMES[dir_name])
			s.port_ios.append(StructureDef.IO_NAMES[io_name])
		s.power_use = int(row.get("power_use", 0))
		s.power_gen = int(row.get("power_gen", 0))
		s.power_radius = int(row.get("power_radius", 0))
		s.params = row.get("params", {})
		if s.kind == StructureDef.Kind.GENERATOR:
			var fuel: Dictionary = s.params.get("fuel", {})
			for fid: String in fuel:
				var idx := item_index(StringName(fid))
				if idx < 0:
					errors.append("%s: 없는 연료 '%s'" % [what, fid])
				else:
					s.fuels[idx] = int(fuel[fid])
			if s.fuels.is_empty() or s.power_gen <= 0 or s.power_radius <= 0:
				errors.append("%s: 발전기는 fuel, power_gen, power_radius 필요" % what)
		structures[s.id] = s

	# 레시피 → 설비 연결. workbench처럼 시뮬레이션 밖 설비도 구조물로는 존재해야 한다.
	for rid: StringName in recipes:
		var r := recipes[rid]
		if r.machines.is_empty():
			errors.append("레시피 %s: machines가 비어 있음" % rid)
		for m in r.machines:
			if not structures.has(m):
				errors.append("레시피 %s: 없는 설비 '%s'" % [rid, m])
			else:
				structures[m].recipes.append(r)


func crop_by_id(id: StringName) -> CropDef:
	for c in crops:
		if c.id == id:
			return c
	return null


## 씨앗 아이템으로 심을 수 있는 작물. 없으면 null.
func crop_for_seed(item: int) -> CropDef:
	for c in crops:
		if c.seed_item == item:
			return c
	return null


func _load_crops(rows: Array) -> void:
	for row: Dictionary in rows:
		var c := CropDef.new()
		c.id = StringName(str(row.get("id", "")))
		c.index = crops.size()
		c.display_name = str(row.get("name", c.id))
		c.seed_item = item_index(StringName(str(row.get("seed", ""))))
		c.product_item = item_index(StringName(str(row.get("product", ""))))
		c.grow_ticks = int(row.get("grow_ticks", 0))
		c.stages = int(row.get("stages", 4))
		c.yield_count = int(row.get("yield", 1))
		c.seed_return = int(row.get("seed_return", 1))
		c.bonus_seed_percent = int(row.get("bonus_seed_percent", 0))
		if c.id == &"" or c.seed_item < 0 or c.product_item < 0 or c.grow_ticks <= 0 or c.stages < 2:
			errors.append("작물 '%s': 씨앗·생산물·성장 시간 값 오류" % c.id)
		crops.append(c)


func _load_rules(path: String) -> void:
	if not FileAccess.file_exists(path):
		errors.append("파일 없음: %s" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		errors.append("JSON 객체가 아님: %s" % path)
		return
	var rules: Dictionary = parsed
	for pair: Variant in rules.get("starting_kit", []):
		var st := _stack("시작 지급품", pair)
		if st.x >= 0:
			starting_kit[st.x] = st.y
	max_build_height = int(rules.get("max_build_height", 48))
	max_decor = int(rules.get("max_decor", 2000))


func _v3(v: Variant) -> Vector3i:
	if v is Array and (v as Array).size() == 3:
		var a: Array = v
		return Vector3i(int(a[0]), int(a[1]), int(a[2]))
	errors.append("3요소 배열이 아님: %s" % str(v))
	return Vector3i.ONE
