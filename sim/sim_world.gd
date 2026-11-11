class_name SimWorld
extends RefCounted
## 공장 시뮬레이션. 호스트가 0.1초마다 tick()을 한 번 부른다.
##
## 규칙 (Blueprint/04_architecture.md):
## - Node, 씬 트리, 오토로드를 쓰지 않는다.
## - 정수 연산만 쓰고, 순회 순서는 항상 구조물 ID 오름차순이나 미리 계산한 순서다.
## - 같은 상태에서 같은 횟수만큼 tick()을 부르면 항상 같은 결과가 나온다.

const SAVE_FORMAT := 1
const DIRV: Array[Vector3i] = [Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(-1, 0, 0)]
const GRID_BUCKET := 32

var db: ContentDB
var tick_count: int = 0
var next_id: int = 1

var structures: Dictionary[int, SimStructure] = {}
var occupancy: Dictionary[Vector3i, int] = {}
var nodes: Dictionary[Vector3i, int] = {}  ## 광맥: 칸 → 아이템 인덱스

# 종류별 목록. 모두 ID 오름차순을 유지한다.
var crafters: Array[SimStructure] = []
var generators: Array[SimStructure] = []
var storages: Array[SimStructure] = []
var junctions: Array[SimStructure] = []
var belts: Array[SimStructure] = []
var providers: Array[SimStructure] = []

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


## 설치할 수 없으면 이유를, 가능하면 빈 문자열을 돌려준다.
func can_place(def_id: StringName, cell: Vector3i, rot: int) -> String:
	var def: StructureDef = db.structures.get(def_id)
	if def == null:
		return "unknown_structure"
	if def.kind == StructureDef.Kind.BELT:
		return "use_place_belt"
	var has_node := false
	for c in footprint_cells(def, cell, rot):
		if occupancy.has(c):
			return "occupied"
		if nodes.has(c):
			has_node = true
	if def.params.get("needs_node", false) and not has_node:
		return "needs_node"
	return ""


func place(def_id: StringName, cell: Vector3i, rot: int = 0, by: String = "", forced_id: int = 0) -> SimStructure:
	if can_place(def_id, cell, rot) != "":
		return null
	var def := db.structures[def_id]
	var s := _new_structure(def, cell, by, forced_id)
	s.rot = rot & 3
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
	if def.power_radius > 0:
		_insert_sorted(providers, s)
	return s


## 벨트 한 줄을 설치한다. 칸은 상류에서 하류 순서이고 이웃한 칸끼리 수평으로 붙어 있어야 한다.
## 한 칸짜리 벨트는 dir로 방향을 준다.
func can_place_belt(path: Array[Vector3i], dir: int = -1) -> String:
	if path.is_empty():
		return "empty_path"
	if path.size() == 1 and (dir < 0 or dir > 3):
		return "needs_dir"
	var seen: Dictionary[Vector3i, bool] = {}
	for i in path.size():
		if occupancy.has(path[i]) or seen.has(path[i]):
			return "occupied"
		seen[path[i]] = true
		if i > 0 and DIRV.find(path[i] - path[i - 1]) < 0:
			return "not_adjacent"
	return ""


func place_belt(def_id: StringName, path: Array[Vector3i], by: String = "", dir: int = -1, forced_id: int = 0) -> SimStructure:
	var def: StructureDef = db.structures.get(def_id)
	if def == null or def.kind != StructureDef.Kind.BELT or can_place_belt(path, dir) != "":
		return null
	var s := _new_structure(def, path[0], by, forced_id)
	s.cells = path.duplicate()
	if path.size() == 1:
		s.dir_in = dir
		s.dir_out = dir
	else:
		s.dir_in = DIRV.find(path[1] - path[0])
		s.dir_out = DIRV.find(path[-1] - path[-2])
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
	var cells := s.cells if s.kind == StructureDef.Kind.BELT else footprint_cells(s.def, s.cell, s.rot)
	for c in cells:
		occupancy.erase(c)
	structures.erase(id)
	for list: Array[SimStructure] in [crafters, generators, storages, junctions, belts, providers]:
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
	if s.kind == StructureDef.Kind.STORAGE and s.store.has(item):
		var n := mini(count, s.store[item])
		_storage_remove(s, item, n)
		return n
	return 0


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

	var t1 := Time.get_ticks_usec()
	# 2. 전력: 수요가 있을 때만 연료를 태운다.
	for gen in generators:
		var grid := gen.grid
		if gen.burn_left == 0 and gen.fuel_count > 0 and grid.demand > 0:
			gen.fuel_count -= 1
			gen.burn_left = gen.def.fuels[gen.fuel_item]
			if gen.fuel_count == 0:
				gen.fuel_item = -1
		if gen.burn_left > 0:
			gen.burn_left -= 1
			grid.supply += gen.def.power_gen
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
	for list: Array[SimStructure] in [crafters, generators, storages, junctions]:
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

	# 소비 설비는 범위 안의 공급원 중 ID가 가장 작은 것의 전력망에 붙는다.
	for m in crafters:
		if m.def.power_use <= 0:
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
		rows.append(row)
	return {
		"format": SAVE_FORMAT, "tick": tick_count, "next_id": next_id,
		"palette": palette, "nodes": node_rows, "structures": rows,
	}


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
			s = w.place_belt(def_id, path, str(row["by"]), int(row["dir"]), int(row["id"]))
		else:
			s = w.place(def_id, cell, int(row["rot"]), str(row["by"]), int(row["id"]))
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
	w.tick_count = int(d["tick"])
	w.next_id = maxi(w.next_id, int(d["next_id"]))
	return w
