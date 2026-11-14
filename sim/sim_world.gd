class_name SimWorld
extends RefCounted
## 공장 시뮬레이션. 호스트가 0.1초마다 tick()을 한 번 부른다.
##
## 규칙 (Blueprint/04_architecture.md):
## - Node, 씬 트리, 오토로드를 쓰지 않는다.
## - 정수 연산만 쓰고, 순회 순서는 항상 구조물 ID 오름차순이나 미리 계산한 순서다.
## - 같은 상태에서 같은 횟수만큼 tick()을 부르면 항상 같은 결과가 나온다.

const SAVE_FORMAT := 4
const DIRV: Array[Vector3i] = [Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0)]
const GRID_BUCKET := 32

var db: ContentDB
var tick_count: int = 0
var next_id: int = 1

var structures: Dictionary[int, SimStructure] = {}
var occupancy: Dictionary[Vector3i, int] = {}
var nodes: Dictionary[Vector3i, int] = {}  ## 광맥: 칸 → 아이템 인덱스
## 바닥판: 칸의 밑면을 덮는다. 칸 자체를 차지하지 않으므로 그 위에 설비를 놓을 수 있다.
var plates: Dictionary[Vector3i, int] = {}
## 벽: 칸의 북쪽(w = 0) 또는 서쪽(w = 3) 모서리에 선다. 키는 (x, y, z, 방향), y는 벽의 밑.
var walls: Dictionary[Vector4i, int] = {}
var decor_count: int = 0
var decors: Array[SimStructure] = []
## 건축 가능 구역: 높이가 정해진 평평한 단. 각 항목은 [x, z, 폭, 깊이, 지면 높이].
## 하나도 없으면 월드 전체가 높이 0의 평지다(테스트와 벤치마크).
var build_zones: Array[PackedInt32Array] = []
## 구역 복원: 구역 인덱스 → 진행도(0..100). 100이면 복원 완료이고 되돌아가지 않는다.
var restore: Dictionary[int, int] = {}
## 우두머리를 쓰러뜨린 구역(구역 인덱스 → true). 다시 나타나지 않는다.
var boss_down: Dictionary[int, bool] = {}
## 손으로 캔 자리: 칸 → 다시 캘 수 있는 틱.
var gather_ready: Dictionary[Vector3i, int] = {}
## 플레이어 소지품: 플레이어 키 → (아이템 인덱스 → 수량). 월드 세이브에 함께 저장된다(D-013).
var inventories: Dictionary[String, Dictionary] = {}

# 종류별 목록. 모두 ID 오름차순을 유지한다.
var crafters: Array[SimStructure] = []
var generators: Array[SimStructure] = []
var storages: Array[SimStructure] = []
var junctions: Array[SimStructure] = []
var belts: Array[SimStructure] = []
var providers: Array[SimStructure] = []
var plots: Array[SimStructure] = []
var beacons: Array[SimStructure] = []
var batteries: Array[SimStructure] = []
var sprinklers: Array[SimStructure] = []
var harvesters: Array[SimStructure] = []

var grids: Array[SimPowerGrid] = []
var belt_order: Array[SimStructure] = []  ## 하류 먼저
var _dirty: bool = true

## 단계별 누적 시간(usec): 준비, 전력, 진행, 벨트, 출력. 성능 패널과 벤치마크용.
var profile: PackedInt64Array = [0, 0, 0, 0, 0]


func _init(content: ContentDB) -> void:
	db = content


# ---------------------------------------------------------------------------
# 좌표
# ---------------------------------------------------------------------------

## 로컬 칸을 시계 방향(위에서 볼 때)으로 rot × 90도 돌린다. 북(-Z) → 동(+X).
static func rotate_cell(v: Vector3i, rot: int) -> Vector3i:
	match rot & 3:
		1: return Vector3i(-v.z, v.y, v.x)
		2: return Vector3i(-v.x, v.y, -v.z)
		3: return Vector3i(v.z, v.y, -v.x)
	return v


static func footprint_cells(def: StructureDef, cell: Vector3i, rot: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for x in def.footprint.x:
		for y in def.footprint.y:
			for z in def.footprint.z:
				out.append(cell + rotate_cell(Vector3i(x, y, z), rot))
	return out


# ---------------------------------------------------------------------------
# 설치 / 철거
# ---------------------------------------------------------------------------

func add_node(cell: Vector3i, item_id: StringName) -> void:
	nodes[cell] = db.item_index(item_id)


const WALL_HEIGHT := 4

## 바닥판이 덮는 칸들.
static func plate_cells(def: StructureDef, cell: Vector3i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for x in def.footprint.x:
		for z in def.footprint.z:
			out.append(cell + Vector3i(x, 0, z))
	return out


## 벽이 차지하는 모서리들. rot이 짝수면 X축을 따라(칸의 북쪽 모서리), 홀수면 Z축을 따라(서쪽 모서리).
static func wall_edges(def: StructureDef, cell: Vector3i, rot: int) -> Array[Vector4i]:
	var out: Array[Vector4i] = []
	for i in def.footprint.x:
		if rot & 1 == 0:
			out.append(Vector4i(cell.x + i, cell.y, cell.z, 0))
		else:
			out.append(Vector4i(cell.x, cell.y, cell.z + i, 3))
	return out


const NO_GROUND := -1000000
const DECOR_MIN_GAP_MM := 300

func add_build_zone(x: int, z: int, width: int, depth: int, ground: int) -> void:
	build_zones.append(PackedInt32Array([x, z, width, depth, ground]))


## 그 자리의 지면 높이. 건축할 수 없는 땅이면 NO_GROUND.
func ground_y(x: int, z: int) -> int:
	if build_zones.is_empty():
		return 0
	for zone in build_zones:
		if x >= zone[0] and x < zone[0] + zone[2] and z >= zone[1] and z < zone[1] + zone[3]:
			return zone[4]
	return NO_GROUND


## 그 칸에 지을 수 있는 땅인가: 건축 구역 안이고, 지면보다 낮지 않고, 높이 한도 안이다.
func _site(c: Vector3i) -> String:
	var g := ground_y(c.x, c.z)
	if g == NO_GROUND:
		return "not_buildable"
	if c.y < g or c.y > g + db.max_build_height:
		return "out_of_bounds"
	return ""


## 그 칸 바로 아래가 받쳐 주는가: 지면이거나, 바닥판이 깔려 있거나, 다른 구조물이 있다.
func _cell_supported(c: Vector3i) -> bool:
	return c.y == ground_y(c.x, c.z) or plates.has(c) or occupancy.has(c + Vector3i(0, -1, 0))


func _plate_supported(cells: Array[Vector3i]) -> bool:
	var y := cells[0].y
	for c in cells:
		if y == ground_y(c.x, c.z):
			return true
	var own: Dictionary[Vector3i, bool] = {}
	for c in cells:
		own[c] = true
	for c in cells:
		# 아래에 구조물(계단 꼭대기, 설비)이 있거나, 같은 높이의 바닥판과 이웃해 있다.
		if occupancy.has(c + Vector3i(0, -1, 0)):
			return true
		for d in DIRV:
			if not own.has(c + d) and plates.has(c + d):
				return true
		# 아래층 벽의 꼭대기가 이 칸의 네 모서리 중 하나에 닿는다.
		var below := y - WALL_HEIGHT
		if walls.has(Vector4i(c.x, below, c.z, 0)) or walls.has(Vector4i(c.x, below, c.z, 3)) \
				or walls.has(Vector4i(c.x, below, c.z + 1, 0)) or walls.has(Vector4i(c.x + 1, below, c.z, 3)):
			return true
	return false


func _wall_supported(e: Vector4i) -> bool:
	if walls.has(Vector4i(e.x, e.y - WALL_HEIGHT, e.z, e.w)):
		return true
	# 모서리 양쪽 칸 중 한 곳이 지면이거나 바닥판이 있다.
	var here := Vector3i(e.x, e.y, e.z)
	var other := here + (Vector3i(0, 0, -1) if e.w == 0 else Vector3i(-1, 0, 0))
	return plates.has(here) or plates.has(other) or e.y == ground_y(here.x, here.z) or e.y == ground_y(other.x, other.z)


## 벽 모서리에 지을 수 있는가: 양쪽 칸 중 하나라도 건축 구역이면 된다.
func _wall_site(e: Vector4i) -> String:
	var here := Vector3i(e.x, e.y, e.z)
	var other := here + (Vector3i(0, 0, -1) if e.w == 0 else Vector3i(-1, 0, 0))
	var a := _site(here)
	return a if a == "" else _site(other)


## 설치할 수 없으면 이유를, 가능하면 빈 문자열을 돌려준다.
## check_support를 끄면 받침 검사를 건너뛴다(저장된 월드를 다시 지을 때).
func can_place(def_id: StringName, cell: Vector3i, rot: int, check_support: bool = true) -> String:
	var def: StructureDef = db.structures.get(def_id)
	if def == null:
		return "unknown_structure"
	if def.kind == StructureDef.Kind.BELT:
		return "use_place_belt"
	if def.kind == StructureDef.Kind.DECOR:
		return "use_place_free"
	if def.kind == StructureDef.Kind.BEACON and check_support:
		# 비콘은 구역마다 정해진 한 자리에만 선다.
		var site_ok := false
		for z in db.zones:
			if z.beacon_site == cell:
				site_ok = true
		if not site_ok:
			return "needs_site"
	match def.kind:
		StructureDef.Kind.FLOOR:
			var cells := plate_cells(def, cell)
			for c in cells:
				if plates.has(c):
					return "occupied"
				if check_support and _site(c) != "":
					return _site(c)
			if check_support and not _plate_supported(cells):
				return "no_support"
			return ""
		StructureDef.Kind.WALL:
			var supported := false
			for e in wall_edges(def, cell, rot):
				if walls.has(e):
					return "occupied"
				if check_support and _wall_site(e) != "":
					return _wall_site(e)
				supported = supported or _wall_supported(e)
			if check_support and not supported:
				return "no_support"
			return ""
	var has_node := false
	var supported := true
	for c in footprint_cells(def, cell, rot):
		if occupancy.has(c):
			return "occupied"
		if check_support and _site(c) != "":
			return _site(c)
		if nodes.has(c):
			has_node = true
		if c.y == cell.y and not _cell_supported(c):
			supported = false
	if def.params.get("needs_node", false) and (not has_node or _mining_recipe(def, cell, rot) == null):
		return "needs_node"
	if check_support and not supported:
		return "no_support"
	return ""


func place(def_id: StringName, cell: Vector3i, rot: int = 0, by: String = "", forced_id: int = 0, check_support: bool = true) -> SimStructure:
	if can_place(def_id, cell, rot, check_support) != "":
		return null
	var def := db.structures[def_id]
	var s := _new_structure(def, cell, by, forced_id)
	s.rot = rot & 3
	match def.kind:
		StructureDef.Kind.FLOOR:
			for c in plate_cells(def, cell):
				plates[c] = s.id
			return s
		StructureDef.Kind.WALL:
			for e in wall_edges(def, cell, s.rot):
				walls[e] = s.id
			return s
	for c in footprint_cells(def, cell, s.rot):
		occupancy[c] = s.id
	match def.kind:
		StructureDef.Kind.CRAFTER:
			if def.params.get("needs_node", false):
				s.recipe = _mining_recipe(def, cell, s.rot)
			elif def.recipes.size() == 1:
				s.recipe = def.recipes[0]
			_reset_crafter_buffers(s)
			_insert_sorted(crafters, s)
		StructureDef.Kind.GENERATOR:
			_insert_sorted(generators, s)
		StructureDef.Kind.STORAGE:
			_insert_sorted(storages, s)
		StructureDef.Kind.JUNCTION:
			_insert_sorted(junctions, s)
		StructureDef.Kind.PLOT:
			_insert_sorted(plots, s)
		StructureDef.Kind.BEACON:
			for z in db.zones:
				if z.beacon_site == cell:
					s.zone = z.index
			_insert_sorted(beacons, s)
		StructureDef.Kind.BATTERY:
			_insert_sorted(batteries, s)
		StructureDef.Kind.SPRINKLER:
			_insert_sorted(sprinklers, s)
		StructureDef.Kind.HARVESTER:
			_insert_sorted(harvesters, s)
	if def.power_radius > 0:
		_insert_sorted(providers, s)
	return s


## 장식을 자유 위치에 놓는다. 위치는 밀리미터, 방향은 도(정수). 칸을 차지하지 않는다.
func can_place_free(def_id: StringName, pos_mm: Vector3i) -> String:
	var def: StructureDef = db.structures.get(def_id)
	if def == null or def.kind != StructureDef.Kind.DECOR:
		return "unknown_structure"
	var g := ground_y(floori(pos_mm.x / 1000.0), floori(pos_mm.z / 1000.0))
	if g == NO_GROUND:
		return "not_buildable"
	if pos_mm.y < g * 1000 - 100 or pos_mm.y > (g + db.max_build_height + WALL_HEIGHT) * 1000:
		return "out_of_bounds"
	if decor_count >= db.max_decor:
		return "too_many"
	# 다른 장식과 거의 같은 자리에는 놓을 수 없다.
	for d in decors:
		if (d.free_pos - pos_mm).length_squared() < DECOR_MIN_GAP_MM * DECOR_MIN_GAP_MM:
			return "occupied"
	return ""


func place_free(def_id: StringName, pos_mm: Vector3i, yaw_deg: int, by: String = "", forced_id: int = 0) -> SimStructure:
	if can_place_free(def_id, pos_mm) != "":
		return null
	var cell := Vector3i(floori(pos_mm.x / 1000.0), floori(pos_mm.y / 1000.0), floori(pos_mm.z / 1000.0))
	var s := _new_structure(db.structures[def_id], cell, by, forced_id)
	s.free_pos = pos_mm
	s.free_yaw = posmod(yaw_deg, 360)
	decor_count += 1
	decors.append(s)
	return s


## 벨트의 한 걸음이 향하는 수평 방향(0..3). 수평으로 한 칸, 높이로는 한 칸까지 오르내릴 수 있다. 아니면 -1.
static func belt_step_dir(from: Vector3i, to: Vector3i) -> int:
	var d := to - from
	if absi(d.y) > 1:
		return -1
	return DIRV.find(Vector3i(d.x, 0, d.z))


## 벨트 한 줄을 설치한다. 칸은 상류에서 하류 순서이고 이웃한 칸끼리 수평으로 붙어 있어야 한다.
## 한 칸짜리 벨트는 dir로 방향을 준다.
func can_place_belt(path: Array[Vector3i], dir: int = -1, check_support: bool = true) -> String:
	if path.is_empty():
		return "empty_path"
	if path.size() == 1 and (dir < 0 or dir > 3):
		return "needs_dir"
	var seen: Dictionary[Vector3i, bool] = {}
	for i in path.size():
		if occupancy.has(path[i]) or seen.has(path[i]):
			return "occupied"
		if check_support and _site(path[i]) != "":
			return _site(path[i])
		seen[path[i]] = true
		if i > 0 and belt_step_dir(path[i - 1], path[i]) < 0:
			return "not_adjacent"
		# 경사 구간(앞이나 뒤 칸과 높이가 다른 칸)은 스스로 버틴다. 평평한 칸은 받침이 있어야 한다.
		var sloped := (i > 0 and path[i - 1].y != path[i].y) or (i < path.size() - 1 and path[i + 1].y != path[i].y)
		if check_support and not sloped and not _cell_supported(path[i]):
			return "no_support"
	return ""


func place_belt(def_id: StringName, path: Array[Vector3i], by: String = "", dir: int = -1, forced_id: int = 0, check_support: bool = true) -> SimStructure:
	var def: StructureDef = db.structures.get(def_id)
	if def == null or def.kind != StructureDef.Kind.BELT or can_place_belt(path, dir, check_support) != "":
		return null
	var s := _new_structure(def, path[0], by, forced_id)
	s.cells = path.duplicate()
	if path.size() == 1:
		s.dir_in = dir
		s.dir_out = dir
	else:
		s.dir_in = belt_step_dir(path[0], path[1])
		s.dir_out = belt_step_dir(path[-2], path[-1])
	s.period = int(def.params.get("period", 5))
	s.slots.resize(path.size())
	for c in path:
		occupancy[c] = s.id
	_insert_sorted(belts, s)
	return s


## 구조물을 철거하고 안에 들어 있던 아이템(인덱스 → 수량)을 돌려준다. 없는 ID면 null.
func remove(id: int) -> Variant:
	var s: SimStructure = structures.get(id)
	if s == null:
		return null
	var contents := contents_of(s)
	match s.kind:
		StructureDef.Kind.BELT:
			for c in s.cells:
				occupancy.erase(c)
		StructureDef.Kind.FLOOR:
			for c in plate_cells(s.def, s.cell):
				plates.erase(c)
		StructureDef.Kind.WALL:
			for e in wall_edges(s.def, s.cell, s.rot):
				walls.erase(e)
		StructureDef.Kind.DECOR:
			decor_count -= 1
		_:
			for c in footprint_cells(s.def, s.cell, s.rot):
				occupancy.erase(c)
	structures.erase(id)
	for list: Array[SimStructure] in [crafters, generators, storages, junctions, belts, providers, plots, decors, beacons,
			batteries, sprinklers, harvesters]:
		list.erase(s)
	_dirty = true
	return contents


func contents_of(s: SimStructure) -> Dictionary[int, int]:
	var out: Dictionary[int, int] = {}
	match s.kind:
		StructureDef.Kind.CRAFTER:
			if s.recipe != null:
				for i in s.recipe.in_items.size():
					# 진행 중이던 제작의 재료도 돌려준다.
					var n := s.in_counts[i] + (s.recipe.in_counts[i] if s.working else 0)
					if n > 0:
						out[s.recipe.in_items[i]] = n
				if s.out_count > 0:
					out[s.recipe.out_item] = out.get(s.recipe.out_item, 0) + s.out_count
		StructureDef.Kind.GENERATOR:
			if s.fuel_count > 0:
				out[s.fuel_item] = s.fuel_count
		StructureDef.Kind.STORAGE:
			out = s.store.duplicate()
		StructureDef.Kind.JUNCTION:
			if s.j_item != 0:
				out[s.j_item - 1] = 1
		StructureDef.Kind.BELT:
			for v in s.slots:
				if v != 0:
					out[v - 1] = out.get(v - 1, 0) + 1
		StructureDef.Kind.HARVESTER:
			if s.out_count > 0 and s.out_item >= 0:
				out[s.out_item] = s.out_count
		StructureDef.Kind.PLOT:
			# 자라던 작물은 씨앗으로 돌려준다.
			if s.crop >= 0:
				out[db.crops[s.crop].seed_item] = 1
	return out


## 제작 기계의 레시피를 바꾼다. 안에 있던 아이템을 돌려준다. 실패하면 null.
func set_recipe(id: int, recipe_id: StringName) -> Variant:
	var s: SimStructure = structures.get(id)
	var r: RecipeDef = db.recipes.get(recipe_id)
	if s == null or s.kind != StructureDef.Kind.CRAFTER or r == null or not s.def.recipes.has(r):
		return null
	if s.def.params.get("needs_node", false):
		return null
	var contents := contents_of(s)
	s.recipe = r
	_reset_crafter_buffers(s)
	return contents


## 플레이어가 손으로 넣는다. 실제로 들어간 수량을 돌려준다.
func insert(id: int, item_id: StringName, count: int) -> int:
	var s: SimStructure = structures.get(id)
	var item := db.item_index(item_id)
	if s == null or item < 0 or s.kind == StructureDef.Kind.BELT or s.kind == StructureDef.Kind.JUNCTION:
		return 0
	var done := 0
	while done < count and _accept(s, item):
		done += 1
	return done


## 플레이어가 손으로 꺼낸다(제작 기계의 생산물, 저장소의 아이템). 실제로 꺼낸 수량을 돌려준다.
func take(id: int, item_id: StringName, count: int) -> int:
	var s: SimStructure = structures.get(id)
	var item := db.item_index(item_id)
	if s == null or item < 0 or count <= 0:
		return 0
	if s.kind == StructureDef.Kind.CRAFTER and s.recipe != null and s.recipe.out_item == item:
		var n := mini(count, s.out_count)
		s.out_count -= n
		return n
	if s.kind == StructureDef.Kind.HARVESTER and s.out_item == item:
		var n := mini(count, s.out_count)
		s.out_count -= n
		return n
	if s.kind == StructureDef.Kind.STORAGE and s.store.has(item):
		var n := mini(count, s.store[item])
		_storage_remove(s, item, n)
		return n
	return 0


# ---------------------------------------------------------------------------
# 소지품, 비용, 손 제작
# ---------------------------------------------------------------------------

## 처음 보는 플레이어면 시작 지급품을 준다. 새로 만들었으면 true.
func ensure_player(key: String) -> bool:
	if inventories.has(key):
		return false
	inventories[key] = db.starting_kit.duplicate()
	return true


func inv_count(key: String, item: int) -> int:
	var inv: Dictionary = inventories.get(key, {})
	return int(inv.get(item, 0))


func inv_add(key: String, item: int, count: int) -> void:
	if count <= 0 or item < 0 or not inventories.has(key):
		return
	var inv: Dictionary = inventories[key]
	inv[item] = int(inv.get(item, 0)) + count


## 있는 만큼만 뺀다. 실제로 뺀 수량을 돌려준다.
func inv_remove(key: String, item: int, count: int) -> int:
	if count <= 0 or not inventories.has(key):
		return 0
	var inv: Dictionary = inventories[key]
	var have := int(inv.get(item, 0))
	var n := mini(have, count)
	if n >= have:
		inv.erase(item)
	else:
		inv[item] = have - n
	return n


func inv_add_all(key: String, items: Dictionary) -> void:
	for item: int in items:
		inv_add(key, item, int(items[item]))


## 설치 비용(아이템 인덱스 → 수량). 벨트는 칸 수에 비례한다.
func build_cost(def: StructureDef, belt_cells: int = 0) -> Dictionary[int, int]:
	var mult := 1
	if def.kind == StructureDef.Kind.BELT:
		var per := maxi(int(def.params.get("cells_per_cost", 1)), 1)
		mult = (belt_cells + per - 1) / per
	var out: Dictionary[int, int] = {}
	for i in def.cost_items.size():
		out[def.cost_items[i]] = def.cost_counts[i] * mult
	return out


func can_afford(key: String, cost: Dictionary[int, int]) -> bool:
	for item: int in cost:
		if inv_count(key, item) < cost[item]:
			return false
	return true


func pay(key: String, cost: Dictionary[int, int]) -> void:
	for item: int in cost:
		inv_remove(key, item, cost[item])


## 구조물의 설치 비용(철거하면 전액 돌려준다, D-017).
func refund_of(s: SimStructure) -> Dictionary[int, int]:
	return build_cost(s.def, s.cells.size())


## 소지품에서 구조물로 넣는다. 들어간 수량을 돌려준다.
func insert_from(key: String, id: int, item_id: StringName, count: int) -> int:
	var item := db.item_index(item_id)
	var n := insert(id, item_id, mini(count, inv_count(key, item)))
	inv_remove(key, item, n)
	return n


## 구조물에서 소지품으로 꺼낸다. 꺼낸 수량을 돌려준다.
func take_to(key: String, id: int, item_id: StringName, count: int) -> int:
	if not inventories.has(key):
		return 0
	var n := take(id, item_id, count)
	inv_add(key, db.item_index(item_id), n)
	return n


## 작업대 손 제작. 재료가 되는 만큼 최대 times번 만든다. 만든 횟수를 돌려준다.
func craft(key: String, recipe_id: StringName, times: int) -> int:
	var r: RecipeDef = db.recipes.get(recipe_id)
	if r == null or not r.machines.has(&"workbench") or not inventories.has(key):
		return 0
	var done := 0
	while done < times:
		for i in r.in_items.size():
			if inv_count(key, r.in_items[i]) < r.in_counts[i]:
				return done
		for i in r.in_items.size():
			inv_remove(key, r.in_items[i], r.in_counts[i])
		inv_add(key, r.out_item, r.out_count)
		done += 1
	return done


# ---------------------------------------------------------------------------
# 밭
# ---------------------------------------------------------------------------

## 밭의 상태를 한 단어로: "empty", "growing", "ready".
func plot_state(s: SimStructure) -> String:
	if s.crop < 0:
		return "empty"
	return "ready" if s.growth >= db.crops[s.crop].grow_ticks else "growing"


func plant(key: String, id: int, seed_id: StringName) -> bool:
	var s: SimStructure = structures.get(id)
	var seed_item := db.item_index(seed_id)
	var crop := db.crop_for_seed(seed_item)
	if s == null or s.kind != StructureDef.Kind.PLOT or s.crop >= 0 or crop == null:
		return false
	if inv_remove(key, seed_item, 1) != 1:
		return false
	s.crop = crop.index
	s.growth = 0
	s.watered = false
	return true


func water(id: int) -> bool:
	var s: SimStructure = structures.get(id)
	if s == null or s.kind != StructureDef.Kind.PLOT or plot_state(s) != "growing" or s.watered:
		return false
	s.watered = true
	return true


## 다 자란 작물을 거둔다. 얻은 것(아이템 인덱스 → 수량), 거둘 수 없으면 빈 사전.
func harvest(key: String, id: int) -> Dictionary[int, int]:
	var out: Dictionary[int, int] = {}
	var s: SimStructure = structures.get(id)
	if s == null or s.kind != StructureDef.Kind.PLOT or plot_state(s) != "ready" or not inventories.has(key):
		return out
	var crop := db.crops[s.crop]
	out[crop.product_item] = crop.yield_count
	# 추가 씨앗은 틱과 구조물 ID로 정해지므로 모든 피어에서 결과가 같다.
	var roll := absi((tick_count * 7919 + s.id * 104729) % 100)
	var seeds := crop.seed_return + (1 if roll < crop.bonus_seed_percent else 0)
	if seeds > 0:
		out[crop.seed_item] = out.get(crop.seed_item, 0) + seeds
	inv_add_all(key, out)
	s.crop = -1
	s.growth = 0
	s.watered = false
	return out


# ---------------------------------------------------------------------------
# 구역 복원, 손 채집
# ---------------------------------------------------------------------------

func zone_progress(zone: int) -> int:
	return restore.get(zone, 0)


func zone_restored(zone: int) -> bool:
	return zone_progress(zone) >= 100


func set_boss_defeated(zone: int) -> void:
	boss_down[zone] = true


func boss_defeated(zone: int) -> bool:
	return boss_down.get(zone, false)


## 그 구역의 비콘. 없으면 null.
func beacon_of(zone: int) -> SimStructure:
	for b in beacons:
		if b.zone == zone:
			return b
	return null


## 광맥이나 결정 덩어리를 손으로 캔다. 얻은 아이템 인덱스, 캘 수 없으면 -1.
func gather(key: String, cell: Vector3i) -> int:
	if not nodes.has(cell) or not inventories.has(key):
		return -1
	var item := nodes[cell]
	if not db.gather_ticks.has(item) or tick_count < int(gather_ready.get(cell, 0)):
		return -1
	gather_ready[cell] = tick_count + db.gather_ticks[item]
	inv_add(key, item, 1)
	return item


## 그 칸에 놓인 출력/입력 포트의 방향. 벨트를 포트에 맞춰 까는 데 쓴다. 없으면 -1.
func port_dir_at(attach_cell: Vector3i, want_output: bool) -> int:
	for d in 4:
		var id: int = occupancy.get(attach_cell - DIRV[d], 0)
		var s: SimStructure = structures.get(id)
		if s == null or s.kind == StructureDef.Kind.BELT:
			continue
		for i in s.def.port_cells.size():
			var dir := (s.def.port_dirs[i] + s.rot) & 3
			if dir != d or s.cell + rotate_cell(s.def.port_cells[i], s.rot) != attach_cell - DIRV[d]:
				continue
			var io := s.def.port_ios[i]
			if io == StructureDef.PortIO.ANY or (io == StructureDef.PortIO.OUT) == want_output:
				return d
	return -1


func count_in(id: int, item_id: StringName) -> int:
	var s: SimStructure = structures.get(id)
	if s == null:
		return 0
	return contents_of(s).get(db.item_index(item_id), 0)


func _new_structure(def: StructureDef, cell: Vector3i, by: String, forced_id: int) -> SimStructure:
	var s := SimStructure.new()
	s.id = forced_id if forced_id > 0 else next_id
	next_id = maxi(next_id, s.id + 1)
	s.def = def
	s.kind = def.kind
	s.cell = cell
	s.placed_by = by
	structures[s.id] = s
	_dirty = true
	return s


func _insert_sorted(list: Array[SimStructure], s: SimStructure) -> void:
	if list.is_empty() or list[-1].id < s.id:
		list.append(s)
		return
	var i := list.size()
	while i > 0 and list[i - 1].id > s.id:
		i -= 1
	list.insert(i, s)


func _mining_recipe(def: StructureDef, cell: Vector3i, rot: int) -> RecipeDef:
	for c in footprint_cells(def, cell, rot):
		if nodes.has(c):
			for r in def.recipes:
				if r.out_item == nodes[c]:
					return r
	return null


func _reset_crafter_buffers(s: SimStructure) -> void:
	s.working = false
	s.progress = 0
	s.out_count = 0
	s.in_counts = PackedInt32Array()
	if s.recipe != null:
		s.in_counts.resize(s.recipe.in_items.size())
	s.state = SimStructure.State.IDLE if s.recipe != null else SimStructure.State.NO_RECIPE


# ---------------------------------------------------------------------------
# 틱
# ---------------------------------------------------------------------------

func tick() -> void:
	if _dirty:
		_rebuild_topology()

	var t0 := Time.get_ticks_usec()
	# 1. 제작 준비: 시작할 수 있는 기계는 재료를 소모하고 전력 수요에 잡힌다.
	for g in grids:
		g.demand = 0
		g.supply = 0
	for m in crafters:
		var r := m.recipe
		if r == null:
			m.state = SimStructure.State.NO_RECIPE
			continue
		if not m.working:
			if m.out_count + r.out_count > _out_cap(r):
				m.state = SimStructure.State.OUTPUT_BLOCKED
				continue
			var ok := true
			for i in r.in_items.size():
				if m.in_counts[i] < r.in_counts[i]:
					ok = false
					break
			if not ok:
				m.state = SimStructure.State.NO_INPUT
				continue
			for i in r.in_items.size():
				m.in_counts[i] -= r.in_counts[i]
			m.working = true
		if m.grid != null:
			m.grid.demand += m.def.power_use

	# 관수기와 수확기는 돌볼 작물이 있을 때만 전력을 쓴다.
	for list: Array[SimStructure] in [sprinklers, harvesters]:
		for s in list:
			if s.grid == null:
				continue
			for p in s.targets:
				if p.crop >= 0:
					s.grid.demand += s.def.power_use
					break

	var t1 := Time.get_ticks_usec()
	# 2. 전력: 수요가 있을 때만 연료를 태운다.
	for gen in generators:
		var grid := gen.grid
		if gen.def.fuels.is_empty():
			# 태양광·풍력: 연료 없이 늘 돈다.
			grid.supply += gen.def.power_gen * gen.bonus_pct / 100
			continue
		if gen.burn_left == 0 and gen.fuel_count > 0 and grid.demand > 0:
			gen.fuel_count -= 1
			gen.burn_left = gen.def.fuels[gen.fuel_item]
			if gen.fuel_count == 0:
				gen.fuel_item = -1
		if gen.burn_left > 0:
			gen.burn_left -= 1
			grid.supply += gen.def.power_gen
	# 축전지: 남으면 채우고 모자라면 내놓는다(ID 순서대로).
	for b in batteries:
		var g := b.grid
		if g == null:
			continue
		var rate := int(b.def.params.get("rate", 0))
		var spare := g.supply - g.demand
		if spare > 0:
			var take_in := mini(mini(rate, spare), int(b.def.params.get("capacity", 0)) - b.charge)
			b.charge += take_in
			g.supply -= take_in   # 저장한 만큼은 이번 틱의 공급에서 빠진다
		elif spare < 0:
			var give := mini(mini(rate, -spare), b.charge)
			b.charge -= give
			g.supply += give
	for g in grids:
		if g.demand <= 0 or g.supply >= g.demand:
			g.ratio = 1000 if g.supply > 0 or g.demand <= 0 else 0
		else:
			g.ratio = g.supply * 1000 / g.demand

	var t2 := Time.get_ticks_usec()
	# 3. 제작 진행.
	for m in crafters:
		if not m.working:
			continue
		var ratio := 1000
		if m.def.power_use > 0:
			ratio = m.grid.ratio if m.grid != null else 0
		if ratio == 0:
			m.state = SimStructure.State.NO_POWER
			continue
		m.state = SimStructure.State.RUNNING
		m.progress += ratio
		if m.progress >= m.recipe.ticks * 1000:
			# 넘친 진행도는 다음 제작으로 넘긴다. 그래야 전력 부족 시 생산량이 충족률에 정확히 비례한다.
			m.working = false
			m.progress -= m.recipe.ticks * 1000
			m.out_count += m.recipe.out_count
			m.produced_total += m.recipe.out_count

	var t3 := Time.get_ticks_usec()
	# 4. 벨트 전진 (하류 먼저).
	for l in belt_order:
		if l.item_count != 0 and tick_count % l.period == 0:
			_step_belt(l)

	var t4 := Time.get_ticks_usec()
	# 5. 출력 포트 → 벨트.
	for m in crafters:
		if m.out_count > 0 and not m.out_lines.is_empty():
			if _belt_push(m.out_lines[0], m.recipe.out_item):
				m.out_count -= 1
	for st in storages:
		if not st.out_lines.is_empty() and not st.store.is_empty():
			var line := st.out_lines[0]
			if line.slots[line.slots.size() - 1] == 0:
				var item: int = st.store.keys()[0]
				_belt_push(line, item)
				_storage_remove(st, item, 1)
	for j in junctions:
		if j.j_item == 0:
			continue
		var n := j.out_lines.size()
		for k in n:
			var idx := (j.rr + k) % n
			if _belt_push(j.out_lines[idx], j.j_item - 1):
				j.j_item = 0
				j.rr = (idx + 1) % n
				break

	# 관수기: 닿는 밭 중 자라는 것에 물을 준다. 수확기: 다 자란 것을 거두고 같은 작물을 다시 심는다.
	for sp in sprinklers:
		if sp.grid == null or sp.grid.ratio <= 0:
			continue
		for p in sp.targets:
			if p.crop >= 0 and not p.watered and p.growth < db.crops[p.crop].grow_ticks:
				p.watered = true
	for h in harvesters:
		if h.grid != null and h.grid.ratio > 0:
			var cap := int(h.def.params.get("buffer", 24))
			for p in h.targets:
				if p.crop < 0 or p.growth < db.crops[p.crop].grow_ticks:
					continue
				var crop := db.crops[p.crop]
				# 한 가지 작물만 담는다. 자리가 없으면 그대로 둔다.
				if (h.out_count > 0 and h.out_item != crop.product_item) or h.out_count + crop.yield_count > cap:
					continue
				h.out_item = crop.product_item
				h.out_count += crop.yield_count
				p.growth = 0
				p.watered = false
		if h.out_count > 0 and not h.out_lines.is_empty():
			if _belt_push(h.out_lines[0], h.out_item):
				h.out_count -= 1

	# 6. 밭: 물을 준 밭은 다음 성장 단계까지 두 배로 자란다.
	for p in plots:
		if p.crop < 0:
			continue
		var crop := db.crops[p.crop]
		if p.growth >= crop.grow_ticks:
			continue
		if p.watered:
			var stage_before := p.growth * (crop.stages - 1) / crop.grow_ticks
			p.growth = mini(p.growth + 2, crop.grow_ticks)
			if p.growth * (crop.stages - 1) / crop.grow_ticks != stage_before:
				p.watered = false
		else:
			p.growth += 1

	var t5 := Time.get_ticks_usec()
	profile[0] += t1 - t0
	profile[1] += t2 - t1
	profile[2] += t3 - t2
	profile[3] += t4 - t3
	profile[4] += t5 - t4
	tick_count += 1


func _out_cap(r: RecipeDef) -> int:
	return maxi(r.out_count * 2, 4)


func _in_cap(need: int) -> int:
	return maxi(need * 2, 4)


func _belt_push(l: SimStructure, item: int) -> bool:
	var last := l.slots.size() - 1
	if l.slots[last] != 0:
		return false
	l.slots[last] = item + 1
	l.item_count += 1
	return true


func _step_belt(l: SimStructure) -> void:
	var head := l.slots[0]
	if head != 0 and l.dst != null and _accept(l.dst, head - 1):
		l.slots[0] = 0
		l.item_count -= 1
		l.passed_total += 1
		head = 0
	if head == 0:
		# 전체가 한 칸 전진한다.
		if l.item_count > 0:
			l.slots.remove_at(0)
			l.slots.push_back(0)
		l.packed = maxi(l.packed - 1, 0)
	else:
		# 머리가 막혔다. 머리 쪽 첫 빈칸 뒤의 물건들만 전진한다.
		var n := l.slots.size()
		var p := l.packed
		while p < n and l.slots[p] != 0:
			p += 1
		l.packed = p
		if p < n:
			l.slots.remove_at(p)
			l.slots.push_back(0)


## 구조물 s가 아이템 하나를 받는다. 받았으면 true.
func _accept(s: SimStructure, item: int) -> bool:
	match s.kind:
		StructureDef.Kind.CRAFTER:
			var r := s.recipe
			if r == null:
				return false
			for i in r.in_items.size():
				if r.in_items[i] == item:
					if s.in_counts[i] >= _in_cap(r.in_counts[i]):
						return false
					s.in_counts[i] += 1
					return true
			return false
		StructureDef.Kind.BELT:
			return _belt_push(s, item)
		StructureDef.Kind.JUNCTION:
			if s.j_item != 0:
				return false
			s.j_item = item + 1
			return true
		StructureDef.Kind.STORAGE:
			var have: int = s.store.get(item, 0)
			if have % db.item_def(item).stack_size == 0:
				if s.store_slots_used >= int(s.def.params.get("slots", 0)):
					return false
				s.store_slots_used += 1
			s.store[item] = have + 1
			return true
		StructureDef.Kind.BEACON:
			if s.zone < 0 or item != db.zones[s.zone].capsule_item or zone_progress(s.zone) >= 100:
				return false
			restore[s.zone] = mini(zone_progress(s.zone) + db.zones[s.zone].capsule_points, 100)
			if restore[s.zone] >= 100:
				# 복원 완료: 그 구역에 건축할 수 있게 된다.
				var u := db.zones[s.zone].unlock_zone
				add_build_zone(u[0], u[1], u[2], u[3], u[4])
				_dirty = true   # 복원된 구역의 친환경 발전 보너스를 다시 계산한다
			return true
		StructureDef.Kind.GENERATOR:
			if not s.def.fuels.has(item) or s.fuel_count >= int(s.def.params.get("fuel_cap", 10)):
				return false
			if s.fuel_count > 0 and s.fuel_item != item:
				return false
			s.fuel_item = item
			s.fuel_count += 1
			return true
	return false


func _storage_remove(s: SimStructure, item: int, n: int) -> void:
	var left := s.store[item] - n
	if left > 0:
		s.store[item] = left
	else:
		s.store.erase(item)
	_recount_storage(s)


func _recount_storage(s: SimStructure) -> void:
	var used := 0
	for item: int in s.store:
		var stack := db.item_def(item).stack_size
		used += (s.store[item] + stack - 1) / stack
	s.store_slots_used = used


# ---------------------------------------------------------------------------
# 토폴로지: 설치·철거가 있었을 때만 다시 계산한다.
# ---------------------------------------------------------------------------

func _rebuild_topology() -> void:
	_dirty = false
	for id: int in structures:
		var s := structures[id]
		s.out_lines.clear()
		s.dst = null
		s.grid = null

	# 포트의 바깥 칸 → [구조물, 방향, 입출력]
	var port_map: Dictionary[Vector3i, Array] = {}
	for list: Array[SimStructure] in [crafters, generators, storages, junctions, beacons, harvesters]:
		for s in list:
			for i in s.def.port_cells.size():
				var dir := (s.def.port_dirs[i] + s.rot) & 3
				var attach := s.cell + rotate_cell(s.def.port_cells[i], s.rot) + DIRV[dir]
				if not port_map.has(attach):
					port_map[attach] = []
				port_map[attach].append([s, dir, s.def.port_ios[i]])

	for l in belts:
		# 꼬리: 출력 포트에서 곧게 나오는 벨트만 연결된다.
		for entry: Array in port_map.get(l.cells[0], []):
			if entry[2] != StructureDef.PortIO.IN and entry[1] == l.dir_in:
				(entry[0] as SimStructure).out_lines.append(l)
				break
		# 머리: 입력 포트로 곧게 들어가는 벨트만 연결된다.
		for entry: Array in port_map.get(l.cells[-1], []):
			if entry[2] != StructureDef.PortIO.OUT and ((entry[1] as int) + 2) & 3 == l.dir_out:
				l.dst = entry[0]
				break
		if l.dst == null:
			var next: SimStructure = structures.get(occupancy.get(l.cells[-1] + DIRV[l.dir_out], 0))
			if next != null and next != l and next.kind == StructureDef.Kind.BELT and next.cells[0] == l.cells[-1] + DIRV[l.dir_out]:
				l.dst = next

	# 벨트 처리 순서: 받는 쪽을 먼저 비워야 주는 쪽이 같은 걸음에 넘길 수 있다.
	belt_order.clear()
	var visited: Dictionary[int, bool] = {}
	for l in belts:
		var chain: Array[SimStructure] = []
		var cur := l
		while cur != null and cur.kind == StructureDef.Kind.BELT and not visited.has(cur.id):
			visited[cur.id] = true
			chain.append(cur)
			cur = cur.dst
		chain.reverse()
		belt_order.append_array(chain)

	_rebuild_power()

	# 관수기와 수확기가 닿는 밭(같은 높이, 가로세로 range칸 안).
	for list: Array[SimStructure] in [sprinklers, harvesters]:
		for s in list:
			s.targets.clear()
			var reach_cells := int(s.def.params.get("range", 0))
			for p in plots:
				var d := p.cell - s.cell
				if d.y == 0 and absi(d.x) <= reach_cells and absi(d.z) <= reach_cells:
					s.targets.append(p)
	# 태양광·풍력은 복원이 끝난 구역 안에서 출력이 1.5배다.
	for gen in generators:
		gen.bonus_pct = 100
		if not gen.def.fuels.is_empty():
			continue
		for z in db.zones:
			var u := z.unlock_zone
			if zone_restored(z.index) and gen.cell.x >= u[0] and gen.cell.x < u[0] + u[2] \
					and gen.cell.z >= u[1] and gen.cell.z < u[1] + u[3]:
				gen.bonus_pct = 150


func _rebuild_power() -> void:
	grids.clear()
	var buckets: Dictionary[Vector2i, Array] = {}
	var max_radius := 0
	for p in providers:
		var key := Vector2i(floori(float(p.cell.x) / GRID_BUCKET), floori(float(p.cell.z) / GRID_BUCKET))
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(p)
		max_radius = maxi(max_radius, p.def.power_radius)
	var reach := ceili(float(max_radius) / GRID_BUCKET)

	# 서로 범위 안에 있는 공급원(발전기, 중계 기둥)을 한 전력망으로 묶는다.
	for p in providers:
		if p.grid != null:
			continue
		var grid := SimPowerGrid.new()
		grids.append(grid)
		p.grid = grid
		var stack: Array[SimStructure] = [p]
		while not stack.is_empty():
			var a: SimStructure = stack.pop_back()
			for b: SimStructure in _providers_near(buckets, a.cell, reach):
				if b.grid == null:
					var r := maxi(a.def.power_radius, b.def.power_radius)
					if (a.cell - b.cell).length_squared() <= r * r:
						b.grid = grid
						stack.append(b)

	# 소비 설비와 축전지는 범위 안의 공급원 중 ID가 가장 작은 것의 전력망에 붙는다.
	for list: Array[SimStructure] in [crafters, batteries, sprinklers, harvesters]:
		for m in list:
			if m.def.power_use <= 0 and m.kind != StructureDef.Kind.BATTERY:
				continue
			var best: SimStructure = null
			for b: SimStructure in _providers_near(buckets, m.cell, reach):
				if (m.cell - b.cell).length_squared() <= b.def.power_radius * b.def.power_radius:
					if best == null or b.id < best.id:
						best = b
			if best != null:
				m.grid = best.grid


func _providers_near(buckets: Dictionary[Vector2i, Array], cell: Vector3i, reach: int) -> Array:
	var out: Array = []
	var bx := floori(float(cell.x) / GRID_BUCKET)
	var bz := floori(float(cell.z) / GRID_BUCKET)
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			out.append_array(buckets.get(Vector2i(bx + dx, bz + dz), []))
	return out


# ---------------------------------------------------------------------------
# 직렬화: 저장과 중도 참가 스냅샷이 같은 형식을 쓴다. 기본형만 담는다.
# ---------------------------------------------------------------------------

func to_dict() -> Dictionary:
	var palette: Array[String] = []
	for id in db.item_ids:
		palette.append(String(id))
	var node_rows: Array = []
	for c: Vector3i in nodes:
		node_rows.append([c.x, c.y, c.z, nodes[c]])
	var rows: Array = []
	var ids := structures.keys()
	ids.sort()
	for id: int in ids:
		var s := structures[id]
		var row := {
			"id": s.id, "def": String(s.def.id), "cell": [s.cell.x, s.cell.y, s.cell.z],
			"rot": s.rot, "by": s.placed_by,
		}
		match s.kind:
			StructureDef.Kind.CRAFTER:
				row["recipe"] = String(s.recipe.id) if s.recipe != null else ""
				row["working"] = s.working
				row["progress"] = s.progress
				row["in"] = s.in_counts
				row["out"] = s.out_count
				row["state"] = s.state
				row["produced"] = s.produced_total
			StructureDef.Kind.GENERATOR:
				row["fuel_item"] = s.fuel_item
				row["fuel"] = s.fuel_count
				row["burn"] = s.burn_left
			StructureDef.Kind.STORAGE:
				var pairs := PackedInt32Array()
				for item: int in s.store:
					pairs.append(item)
					pairs.append(s.store[item])
				row["store"] = pairs
			StructureDef.Kind.JUNCTION:
				row["j_item"] = s.j_item
				row["rr"] = s.rr
			StructureDef.Kind.BELT:
				var flat := PackedInt32Array()
				for c in s.cells:
					flat.append(c.x)
					flat.append(c.y)
					flat.append(c.z)
				row["cells"] = flat
				row["dir"] = s.dir_out
				row["slots"] = s.slots
				row["passed"] = s.passed_total
			StructureDef.Kind.BATTERY:
				row["charge"] = s.charge
			StructureDef.Kind.HARVESTER:
				row["out_item"] = s.out_item
				row["out"] = s.out_count
			StructureDef.Kind.PLOT:
				row["crop"] = String(db.crops[s.crop].id) if s.crop >= 0 else ""
				row["growth"] = s.growth
				row["watered"] = s.watered
			StructureDef.Kind.DECOR:
				row["pos"] = [s.free_pos.x, s.free_pos.y, s.free_pos.z]
				row["yaw"] = s.free_yaw
		rows.append(row)
	var inv_rows: Array = []
	for key: String in inventories:
		var pairs := PackedInt32Array()
		var inv: Dictionary = inventories[key]
		for item: int in inv:
			pairs.append(item)
			pairs.append(int(inv[item]))
		inv_rows.append([key, pairs])
	return {
		"format": SAVE_FORMAT, "tick": tick_count, "next_id": next_id,
		"palette": palette, "nodes": node_rows, "structures": rows, "inventories": inv_rows,
		"zones": build_zones.duplicate(),
		"restore": _restore_rows(), "gather": _gather_rows(),
	}


func _restore_rows() -> Array:
	var out: Array = []
	for z in db.zones:
		if restore.has(z.index) or boss_down.has(z.index):
			out.append([String(z.id), zone_progress(z.index), boss_defeated(z.index)])
	return out


func _gather_rows() -> Array:
	# 이미 지난 것은 저장하지 않는다(있든 없든 결과가 같다).
	var out: Array = []
	for cell: Vector3i in gather_ready:
		if gather_ready[cell] > tick_count:
			out.append([cell.x, cell.y, cell.z, gather_ready[cell]])
	out.sort()
	return out


## 상태 전체의 해시. 호스트와 클라이언트의 시뮬레이션이 어긋났는지 비교하는 데 쓴다.
func state_hash() -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(var_to_bytes(to_dict()))
	return ctx.finish().hex_encode()


## 저장된 상태에서 월드를 만든다. 형식이 맞지 않으면 null.
static func from_dict(content: ContentDB, d: Dictionary) -> SimWorld:
	if int(d.get("format", -1)) != SAVE_FORMAT:
		return null
	var w := SimWorld.new(content)
	# 저장 당시의 아이템 인덱스 → 지금의 인덱스
	var remap := PackedInt32Array()
	for id: String in d["palette"]:
		remap.append(content.item_index(StringName(id)))
	for zone: PackedInt32Array in d.get("zones", []):
		w.build_zones.append(zone)
	for n: Array in d["nodes"]:
		w.nodes[Vector3i(int(n[0]), int(n[1]), int(n[2]))] = remap[int(n[3])]
	for row: Dictionary in d["structures"]:
		var def_id := StringName(str(row["def"]))
		var def: StructureDef = content.structures.get(def_id)
		if def == null:
			continue
		var c: Array = row["cell"]
		var cell := Vector3i(int(c[0]), int(c[1]), int(c[2]))
		var s: SimStructure
		if def.kind == StructureDef.Kind.BELT:
			var flat: PackedInt32Array = row["cells"]
			var path: Array[Vector3i] = []
			for i in range(0, flat.size(), 3):
				path.append(Vector3i(flat[i], flat[i + 1], flat[i + 2]))
			s = w.place_belt(def_id, path, str(row["by"]), int(row["dir"]), int(row["id"]), false)
		elif def.kind == StructureDef.Kind.DECOR:
			var p: Array = row["pos"]
			s = w.place_free(def_id, Vector3i(int(p[0]), int(p[1]), int(p[2])), int(row["yaw"]), str(row["by"]), int(row["id"]))
		else:
			# 받침이 나중에 철거됐을 수 있으므로 받침 검사 없이 다시 짓는다.
			s = w.place(def_id, cell, int(row["rot"]), str(row["by"]), int(row["id"]), false)
		if s == null:
			continue
		match def.kind:
			StructureDef.Kind.CRAFTER:
				s.recipe = content.recipes.get(StringName(str(row["recipe"])))
				w._reset_crafter_buffers(s)
				if s.recipe != null:
					s.working = bool(row["working"])
					s.progress = int(row["progress"])
					s.in_counts = PackedInt32Array(row["in"])
					s.out_count = int(row["out"])
					s.state = int(row["state"])
					s.produced_total = int(row["produced"])
			StructureDef.Kind.BATTERY:
				s.charge = int(row.get("charge", 0))
			StructureDef.Kind.HARVESTER:
				var saved_item := int(row.get("out_item", -1))
				s.out_item = remap[saved_item] if saved_item >= 0 else -1
				s.out_count = int(row.get("out", 0)) if s.out_item >= 0 else 0
			StructureDef.Kind.PLOT:
				var crop := content.crop_by_id(StringName(str(row["crop"])))
				s.crop = crop.index if crop != null else -1
				s.growth = int(row["growth"])
				s.watered = bool(row["watered"])
			StructureDef.Kind.GENERATOR:
				s.fuel_item = remap[int(row["fuel_item"])] if int(row["fuel_item"]) >= 0 else -1
				s.fuel_count = int(row["fuel"])
				s.burn_left = int(row["burn"])
			StructureDef.Kind.STORAGE:
				var pairs: PackedInt32Array = row["store"]
				for i in range(0, pairs.size(), 2):
					s.store[remap[pairs[i]]] = pairs[i + 1]
				w._recount_storage(s)
			StructureDef.Kind.JUNCTION:
				s.j_item = remap[int(row["j_item"]) - 1] + 1 if int(row["j_item"]) != 0 else 0
				s.rr = int(row["rr"])
			StructureDef.Kind.BELT:
				var slots: PackedInt32Array = row["slots"]
				for i in mini(slots.size(), s.slots.size()):
					if slots[i] != 0:
						s.slots[i] = remap[slots[i] - 1] + 1
						s.item_count += 1
				s.passed_total = int(row["passed"])
	for r: Array in d.get("restore", []):
		var zone_def := content.zone_by_id(StringName(str(r[0])))
		if zone_def != null:
			if int(r[1]) > 0:
				w.restore[zone_def.index] = int(r[1])
			if bool(r[2]):
				w.boss_down[zone_def.index] = true
	for g: Array in d.get("gather", []):
		w.gather_ready[Vector3i(int(g[0]), int(g[1]), int(g[2]))] = int(g[3])
	for inv_row: Array in d.get("inventories", []):
		var inv: Dictionary = {}
		var pairs: PackedInt32Array = inv_row[1]
		for i in range(0, pairs.size(), 2):
			if remap[pairs[i]] >= 0 and pairs[i + 1] > 0:
				inv[remap[pairs[i]]] = pairs[i + 1]
		w.inventories[str(inv_row[0])] = inv
	w.tick_count = int(d["tick"])
	w.next_id = maxi(w.next_id, int(d["next_id"]))
	return w
