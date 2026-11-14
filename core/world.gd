extends Node
## 오토로드. 월드 상태(지금은 공장 시뮬레이션)의 유일한 변경 창구.
##
## - 호스트: 0.1초마다 sim.tick(). 요청을 검증하고 적용한 뒤 "몇 틱에 무엇을 했는지"를 방송한다.
## - 클라이언트: 같은 시뮬레이션을 호스트의 틱 번호를 따라 돌린다. 이벤트는 표시된 틱까지
##   먼저 진행한 뒤 적용하므로, 시뮬레이션이 결정론적인 한 호스트와 완전히 같은 상태가 된다.
##   주기적으로 해시를 비교하고, 다르면 스냅샷을 다시 받는다.

signal reset                                   ## 시뮬레이션이 통째로 바뀜(새 월드, 스냅샷 적용)
signal structure_added(s: SimStructure)
signal structure_removed(id: int)
signal ticked(tick: int)
signal request_rejected(reason: String)
signal desynced(tick: int)
signal inventory_changed                       ## 누군가의 소지품이 바뀌었을 수 있다
signal items_gained(key: String, items: Dictionary)   ## 수확·전리품으로 얻음(아이템 ID → 수량)
signal consumed(key: String, item_id: StringName, count: int)
signal zone_progress_changed(zone: int, progress: int)
signal boss_defeated(zone: int)
signal tech_researched(tech_id: StringName, by: String)
signal spawn_assigned(pos: Vector3, yaw: float)  ## 저장된 내 위치를 호스트가 알려 줬다
signal remote_player_state(peer_id: int, pos: Vector3, yaw: float, pitch: float, crouch: bool)

const TICK_SECONDS := 0.1
const CHECKSUM_INTERVAL := 100
const SNAPSHOT_CHUNK := 60000
const MAX_COORD := 1000000
const MAX_BELT_CELLS := 256
const USE_RANGE := 10.0          ## 구조물을 쓰려면 이 거리 안에 있어야 한다
const MAX_PLAYER_SPEED := 40.0   ## m/s. 이보다 빠른 이동 보고는 무시한다.
## 개발용 월드의 광맥 자리(기준 생산 라인의 원점). 실제 맵이 생기면 맵 데이터로 대체한다.
const MAP_PATH := "res://data/map_slice.json"
const GATHER_RANGE := 5.0
## 개발용 부하 시험 구역: 기준 생산 라인을 격자로 깐다(프레임 측정용).
const DEV_STRESS_ZONE: Array[int] = [-184, 88, 368, 96, 0]
const DEV_STRESS_LINES := 72     ## 설비 504개
const DEV_LINE_ORIGINS: Array[Vector3i] = [
	Vector3i(-24, 0, -45), Vector3i(-8, 0, -45), Vector3i(8, 0, -45), Vector3i(24, 0, -45),
]

var sim: SimWorld
var running: bool = false
var tick_enabled: bool = true     ## 끄면 호스트가 틱을 돌리지 않는다(점검용)
var resync_count: int = 0

var _accum: float = 0.0
var _map: Dictionary = {}
var _zone_seen: Dictionary[int, int] = {}
var _target_tick: int = 0
var _synced: Array[int] = []                       ## 호스트: 스냅샷을 받은 피어
var _snapshot_parts: Array[PackedByteArray] = []   ## 클라이언트: 받는 중인 스냅샷
var _snapshot_size: int = 0
## 피어 → 마지막으로 알려진 위치. 호스트는 전원의 위치를, 클라이언트는 자신과 받은 사람들의 위치를 안다.
var positions: Dictionary[int, Vector3] = {}
var yaws: Dictionary[int, float] = {}
## 플레이어 키 → [x, y, z, yaw]. 저장 파일에서 온 것과, 나간 사람의 마지막 위치.
var saved_positions: Dictionary = {}
## 클라이언트: 호스트가 알려 준 내 시작 위치([위치, yaw]). 없으면 빈 배열.
var my_spawn: Array = []
## 월드 설정(세이브에 저장). 지금은 난이도뿐이다.
var settings: Dictionary = {"difficulty": "normal"}
const DIFFICULTIES: Array[String] = ["easy", "normal", "hard"]
const DIFFICULTY_NAMES: Dictionary[String, String] = {"easy": "쉬움", "normal": "보통", "hard": "어려움"}
var _last_player_time: Dictionary[int, float] = {}


func start_new() -> void:
	sim = SimWorld.new(Registry.db)
	saved_positions = {}
	# 맵 데이터: 건축 구역, 광맥과 결정 덩어리, 처음부터 놓여 있는 구조물.
	for z: Array in map_data().get("build_zones", []):
		sim.add_build_zone(int(z[0]), int(z[1]), int(z[2]), int(z[3]), int(z[4]))
	for n: Array in map_data().get("nodes", []):
		sim.add_node(Vector3i(int(n[0]), int(n[1]), int(n[2])), StringName(str(n[3])))
	for st: Array in map_data().get("structures", []):
		sim.place(StringName(str(st[0])), Vector3i(int(st[1]), int(st[2]), int(st[3])), int(st[4]), "world")
	sim.ensure_player(_player_key(1))
	_synced.clear()
	_accum = 0.0
	_zone_seen.clear()
	running = true
	reset.emit()


## 맵 데이터(data/map_slice.json). 지형은 씬이 만들고, 규칙에 필요한 좌표만 여기 있다.
func map_data() -> Dictionary:
	if _map.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAP_PATH))
		if parsed is Dictionary:
			_map = parsed
		else:
			push_error("[World] 맵 데이터를 읽을 수 없음: %s" % MAP_PATH)
	return _map


## 구역 진행도가 바뀌었으면 알린다(이벤트로도, 벨트로 캡슐이 들어가는 틱에서도 바뀔 수 있다).
func _check_zones() -> void:
	for z in Registry.db.zones:
		var p := sim.zone_progress(z.index)
		if p != int(_zone_seen.get(z.index, 0)):
			_zone_seen[z.index] = p
			zone_progress_changed.emit(z.index, p)


## 저장된 월드로 시작한다.
func start_loaded(loaded: SimWorld, players: Dictionary, saved_settings: Dictionary = {}) -> void:
	sim = loaded
	settings = {"difficulty": "normal"}
	settings.merge(saved_settings, true)
	if not DIFFICULTIES.has(str(settings.get("difficulty"))):
		settings["difficulty"] = "normal"
	saved_positions = players.duplicate(true)
	_zone_seen.clear()
	sim.ensure_player(_player_key(1))
	_synced.clear()
	_accum = 0.0
	running = true
	reset.emit()


## 적의 체력·피해 배율 [체력, 피해].
func difficulty_mult() -> Array:
	var table: Dictionary = Registry.db.difficulty
	return table.get(str(settings.get("difficulty", "normal")), [1.0, 1.0])


func difficulty_name() -> String:
	return DIFFICULTY_NAMES.get(str(settings.get("difficulty", "normal")), "?")


## 호스트: 난이도를 다음 단계로 바꾼다. 이미 나와 있는 적에는 적용되지 않는다.
func cycle_difficulty() -> void:
	var i := DIFFICULTIES.find(str(settings.get("difficulty", "normal")))
	settings["difficulty"] = DIFFICULTIES[(i + 1) % DIFFICULTIES.size()]


## 저장할 플레이어 위치: 지금 접속 중인 사람은 현재 위치, 나간 사람은 마지막 위치.
func positions_for_save() -> Dictionary:
	var out := saved_positions.duplicate(true)
	for peer: int in positions:
		if Net.players.has(peer):
			var p := positions[peer]
			out[_player_key(peer)] = [p.x, p.y, p.z, float(yaws.get(peer, 0.0))]
	return out


## 그 플레이어의 저장된 위치([위치, yaw]). 없으면 빈 배열.
func saved_spawn(key: String) -> Array:
	var v: Variant = saved_positions.get(key)
	if v is Array and (v as Array).size() == 4:
		return [Vector3(v[0], v[1], v[2]), float(v[3])]
	return []


func stop() -> void:
	running = false
	_synced.clear()
	_snapshot_parts.clear()


func forget_peer(peer_id: int) -> void:
	if positions.has(peer_id) and Net.players.has(peer_id):
		var p := positions[peer_id]
		saved_positions[_player_key(peer_id)] = [p.x, p.y, p.z, float(yaws.get(peer_id, 0.0))]
	yaws.erase(peer_id)
	_synced.erase(peer_id)
	positions.erase(peer_id)
	_last_player_time.erase(peer_id)


## 호스트: 월드 스냅샷을 받아 이벤트를 받을 수 있는 피어들.
func synced_peers() -> Array[int]:
	return _synced


## 틱과 틱 사이의 진행 비율(0..1). 화면 보간용.
func tick_fraction() -> float:
	return clampf(_accum / TICK_SECONDS, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	if not running:
		return
	_accum += delta
	if multiplayer.is_server() and not tick_enabled:
		_accum = 0.0
	elif multiplayer.is_server():
		while _accum >= TICK_SECONDS:
			_accum -= TICK_SECONDS
			sim.tick()
			for p in _synced:
				_ev_tick.rpc_id(p, sim.tick_count)
			if sim.tick_count % CHECKSUM_INTERVAL == 0 and not _synced.is_empty():
				var h := sim.state_hash()
				for p in _synced:
					_ev_checksum.rpc_id(p, sim.tick_count, h)
			_check_zones()
			ticked.emit(sim.tick_count)
	else:
		# 밀렸으면 한 프레임에 여러 틱을 따라잡되, 화면이 멈추지 않게 상한을 둔다.
		var steps := 0
		while sim.tick_count < _target_tick and steps < 30:
			_tick_client()
			steps += 1
		if _accum > TICK_SECONDS:
			_accum = TICK_SECONDS


func _tick_client() -> void:
	sim.tick()
	_check_zones()
	_accum = 0.0
	ticked.emit(sim.tick_count)


func _advance_to(tick: int) -> void:
	while sim.tick_count < tick:
		_tick_client()
	_target_tick = maxi(_target_tick, tick)


# ---------------------------------------------------------------------------
# 요청 (누구나 → 호스트). 호스트 자신의 입력도 같은 검증을 거친다.
#
# 모든 변경은 (작업 이름, 인자 배열) 한 쌍이다. 호스트가 검증해 이벤트 인자를 만들고,
# 호스트와 클라이언트가 같은 _apply()로 적용한다.
# ---------------------------------------------------------------------------

func request(op: String, args: Array) -> void:
	if not running:
		return
	if multiplayer.is_server():
		_do(1, op, args)
	else:
		_req.rpc_id(1, op, args)


func request_place(def_id: StringName, cell: Vector3i, rot: int) -> void:
	request("place", [String(def_id), cell, rot])


func request_place_belt(def_id: StringName, path: Array[Vector3i], dir: int = -1) -> void:
	request("belt", [String(def_id), _flatten(path), dir])


func request_place_free(def_id: StringName, pos: Vector3, yaw_deg: int) -> void:
	request("free", [String(def_id), Vector3i((pos * 1000.0).round()), yaw_deg])


func request_remove(id: int) -> void:
	request("remove", [id])


## 내 플레이어 키(소지품의 주인 이름).
func my_key() -> String:
	return _player_key(multiplayer.get_unique_id())


func my_inventory() -> Dictionary:
	return sim.inventories.get(my_key(), {}) if sim != null else {}


func my_count(item_id: StringName) -> int:
	return sim.inv_count(my_key(), Registry.db.item_index(item_id)) if sim != null else 0


## 호스트: 새로 들어온 플레이어를 월드에 등록한다(처음이면 시작 지급품, 전에 왔던 사람이면 마지막 위치).
func register_player(peer_id: int) -> void:
	if multiplayer.is_server() and running:
		_emit_event("join", [_player_key(peer_id)])
		var spawn := saved_spawn(_player_key(peer_id))
		if not spawn.is_empty():
			_ev_spawn.rpc_id(peer_id, spawn[0], spawn[1])


@rpc("authority", "call_remote", "reliable")
func _ev_spawn(pos: Vector3, yaw: float) -> void:
	my_spawn = [pos, yaw]
	spawn_assigned.emit(pos, yaw)


## 호스트(개발용): 부하 시험 구역에 기준 생산 라인을 한꺼번에 짓는다. 지은 설비 수를 돌려준다.
func dev_stress() -> int:
	if not multiplayer.is_server() or not running:
		return 0
	var before := sim.structures.size() - sim.belts.size()
	_emit_event("stress", [DEV_STRESS_LINES])
	return sim.structures.size() - sim.belts.size() - before


## 호스트: 구역의 우두머리가 쓰러졌다. 근처에 있던 플레이어 모두에게 에너지 코어를 준다.
func report_boss_defeated(zone: int, peers: Array[int]) -> void:
	if not multiplayer.is_server() or not running:
		return
	var keys: Array[String] = []
	for p in peers:
		keys.append(_player_key(p))
	_emit_event("boss", [zone, keys])


## 호스트: 아이템을 준다(전리품 등). items는 아이템 ID(문자열) → 수량.
func grant(peer_id: int, items: Dictionary) -> void:
	if multiplayer.is_server() and running and not items.is_empty():
		_emit_event("grant", [_player_key(peer_id), items])


@rpc("any_peer", "call_remote", "reliable")
func _req(op: String, args: Array) -> void:
	if multiplayer.is_server() and running:
		_do(multiplayer.get_remote_sender_id(), op, args)


## 호스트: 요청을 검증하고, 통과하면 이벤트로 적용·방송한다.
func _do(sender: int, op: String, a: Array) -> void:
	if not Net.players.has(sender):
		return
	var by := _player_key(sender)
	var why := ""
	var ev: Array = []
	match op:
		"place":
			if not _types(a, [TYPE_STRING, TYPE_VECTOR3I, TYPE_INT]) or not _cell_ok(a[1]) or a[2] < 0 or a[2] > 3:
				why = "bad_request"
			elif not Net.may_build(sender):
				why = "no_permission"
			else:
				why = sim.can_place(StringName(a[0]), a[1], a[2])
				if why == "" and not sim.structure_unlocked(Registry.db.structures[StringName(a[0])]):
					why = "locked"
				if why == "" and not sim.can_afford(by, sim.build_cost(Registry.db.structures[StringName(a[0])])):
					why = "cannot_afford"
				ev = [a[0], a[1], a[2], by, sim.next_id]
		"belt":
			if not _types(a, [TYPE_STRING, TYPE_PACKED_INT32_ARRAY, TYPE_INT]) or a[1].size() % 3 != 0 \
					or a[1].size() == 0 or a[1].size() > MAX_BELT_CELLS * 3 or a[2] < -1 or a[2] > 3:
				why = "bad_request"
			elif not Net.may_build(sender):
				why = "no_permission"
			else:
				var def: StructureDef = Registry.db.structures.get(StringName(a[0]))
				var path := _unflatten(a[1])
				for c in path:
					if not _cell_ok(c):
						why = "bad_request"
				if why == "" and (def == null or def.kind != StructureDef.Kind.BELT):
					why = "unknown_structure"
				if why == "" and not sim.structure_unlocked(def):
					why = "locked"
				if why == "":
					why = sim.can_place_belt(path, a[2])
				if why == "" and not sim.can_afford(by, sim.build_cost(def, path.size())):
					why = "cannot_afford"
				ev = [a[0], a[1], a[2], by, sim.next_id]
		"free":
			if not _types(a, [TYPE_STRING, TYPE_VECTOR3I, TYPE_INT]) or not _cell_ok(a[1] / 1000):
				why = "bad_request"
			elif not Net.may_build(sender):
				why = "no_permission"
			else:
				why = sim.can_place_free(StringName(a[0]), a[1])
				if why == "" and not _near(sender, Vector3(a[1]) / 1000.0, 20.0):
					why = "too_far"
				if why == "" and not sim.can_afford(by, sim.build_cost(Registry.db.structures[StringName(a[0])])):
					why = "cannot_afford"
				ev = [a[0], a[1], a[2], by, sim.next_id]
		"remove":
			if not _types(a, [TYPE_INT]):
				why = "bad_request"
			elif not Net.may_build(sender):
				why = "no_permission"
			elif not sim.structures.has(a[0]):
				why = "not_found"
			ev = [a[0], by]
		"insert", "take":
			if not _types(a, [TYPE_INT, TYPE_STRING, TYPE_INT]) or a[2] <= 0 or a[2] > 100000:
				why = "bad_request"
			else:
				why = _check_use(sender, a[0])
				if why == "" and Registry.db.item_index(StringName(a[1])) < 0:
					why = "not_found"
			ev = [a[0], a[1], a[2], by]
		"recipe":
			if not _types(a, [TYPE_INT, TYPE_STRING]):
				why = "bad_request"
			else:
				why = _check_use(sender, a[0])
				var s: SimStructure = sim.structures.get(a[0])
				var r: RecipeDef = Registry.db.recipes.get(StringName(a[1]))
				if why == "" and (s.kind != StructureDef.Kind.CRAFTER or r == null or not s.def.recipes.has(r) \
						or s.def.params.get("needs_node", false)):
					why = "bad_request"
			ev = [a[0], a[1], by]
		"craft":
			if not _types(a, [TYPE_STRING, TYPE_INT]) or a[1] <= 0 or a[1] > 100:
				why = "bad_request"
			elif not _near_workbench(sender):
				why = "need_workbench"
			elif Registry.db.recipes.has(StringName(a[0])) and not sim.recipe_unlocked(Registry.db.recipes[StringName(a[0])]):
				why = "locked"
			ev = [a[0], a[1], by]
		"research":
			if not _types(a, [TYPE_STRING]):
				why = "bad_request"
			elif not _near_workbench(sender):
				why = "need_workbench"
			else:
				why = sim.can_research(by, StringName(a[0]))
			ev = [a[0], by]
		"plant":
			if not _types(a, [TYPE_INT, TYPE_STRING]):
				why = "bad_request"
			else:
				why = _check_use(sender, a[0])
			ev = [a[0], a[1], by]
		"water", "harvest":
			if not _types(a, [TYPE_INT]):
				why = "bad_request"
			else:
				why = _check_use(sender, a[0])
			ev = [a[0], by]
		"consume":
			if not _types(a, [TYPE_STRING, TYPE_INT]) or a[1] <= 0 or a[1] > 1000:
				why = "bad_request"
			ev = [a[0], a[1], by]
		"gather":
			if not _types(a, [TYPE_VECTOR3I]) or not _cell_ok(a[0]):
				why = "bad_request"
			elif not sim.nodes.has(a[0]) or not Registry.db.gather_ticks.has(sim.nodes[a[0]]):
				why = "not_found"
			elif not _near(sender, Vector3(a[0]) + Vector3(0.5, 0, 0.5), GATHER_RANGE):
				why = "too_far"
			elif sim.tick_count < int(sim.gather_ready.get(a[0], 0)):
				why = "not_ready"
			ev = [a[0], by]
		_:
			why = "bad_request"
	if why != "":
		_reject(sender, why)
		return
	_emit_event(op, ev)


func _emit_event(op: String, ev: Array) -> void:
	_apply(op, ev)
	for p in _synced:
		_ev.rpc_id(p, sim.tick_count, op, ev)


## 구조물을 쓸 수 있는가: 존재하고, 가까이 있다. (방문자도 설비는 쓸 수 있다.)
func _check_use(sender: int, id: Variant) -> String:
	var s: SimStructure = sim.structures.get(id)
	if s == null:
		return "not_found"
	return "" if _near(sender, Vector3(s.cell), USE_RANGE) else "too_far"


func _near(peer_id: int, pos: Vector3, max_dist: float) -> bool:
	return positions.has(peer_id) and positions[peer_id].distance_to(pos) <= max_dist


func _near_workbench(peer_id: int) -> bool:
	for id: int in sim.structures:
		var s := sim.structures[id]
		if s.kind == StructureDef.Kind.WORKBENCH and _near(peer_id, Vector3(s.cell), USE_RANGE):
			return true
	return false


func _types(a: Array, types: Array) -> bool:
	if a.size() != types.size():
		return false
	for i in a.size():
		if typeof(a[i]) != types[i]:
			return false
	return true


func _reject(sender: int, reason: String) -> void:
	if sender == 1:
		request_rejected.emit(reason)
	else:
		_ev_rejected.rpc_id(sender, reason)


func _player_key(peer_id: int) -> String:
	# Steam 연동 전까지는 접속 이름을 쓴다. 이후 Steam ID로 바꾼다.
	return str((Net.players.get(peer_id, {}) as Dictionary).get("name", "p%d" % peer_id))


# ---------------------------------------------------------------------------
# 이벤트 (호스트 → 클라이언트): 호스트가 그 일을 적용한 틱과 함께 온다.
# ---------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _ev_tick(tick: int) -> void:
	if running:
		_target_tick = maxi(_target_tick, tick)


@rpc("authority", "call_remote", "reliable")
func _ev(tick: int, op: String, ev: Array) -> void:
	if running:
		_advance_to(tick)
		_apply(op, ev)


## 호스트와 클라이언트가 똑같이 실행하는 상태 변경. 여기서는 검증하지 않는다.
func _apply(op: String, a: Array) -> void:
	var db := Registry.db
	match op:
		"place":
			var def := db.structures[StringName(a[0])]
			sim.pay(a[3], sim.build_cost(def))
			_added(sim.place(def.id, a[1], a[2], a[3], a[4]))
		"belt":
			var def := db.structures[StringName(a[0])]
			var path := _unflatten(a[1])
			sim.pay(a[3], sim.build_cost(def, path.size()))
			_added(sim.place_belt(def.id, path, a[3], a[2], a[4]))
		"free":
			var def := db.structures[StringName(a[0])]
			sim.pay(a[3], sim.build_cost(def))
			_added(sim.place_free(def.id, a[1], a[2], a[3], a[4]))
		"remove":
			var s: SimStructure = sim.structures.get(a[0])
			if s != null:
				# 설치 비용 전액과 안에 든 것을 철거한 사람에게 돌려준다.
				sim.inv_add_all(a[1], sim.refund_of(s))
				sim.inv_add_all(a[1], sim.remove(a[0]))
				structure_removed.emit(a[0])
		"insert":
			sim.insert_from(a[3], a[0], StringName(a[1]), a[2])
		"take":
			sim.take_to(a[3], a[0], StringName(a[1]), a[2])
		"recipe":
			var back: Variant = sim.set_recipe(a[0], StringName(a[1]))
			if back != null:
				sim.inv_add_all(a[2], back)
		"craft":
			sim.craft(a[2], StringName(a[0]), a[1])
		"plant":
			sim.plant(a[2], a[0], StringName(a[1]))
		"water":
			sim.water(a[0])
		"harvest":
			var got := sim.harvest(a[1], a[0])
			if not got.is_empty():
				items_gained.emit(a[1], _named(got))
		"consume":
			var n := sim.inv_remove(a[2], db.item_index(StringName(a[0])), a[1])
			consumed.emit(a[2], StringName(a[0]), n)
		"research":
			if sim.research(a[1], StringName(a[0])):
				tech_researched.emit(StringName(a[0]), a[1])
		"gather":
			var item := sim.gather(a[1], a[0])
			if item >= 0:
				items_gained.emit(a[1], {String(db.item_ids[item]): 1})
		"boss":
			sim.set_boss_defeated(a[0])
			var core := db.item_index(&"energy_core")
			for key: String in a[1]:
				sim.inv_add(key, core, 1)
				items_gained.emit(key, {"energy_core": 1})
			boss_defeated.emit(a[0])
		"stress":
			_apply_stress(a[0])
			reset.emit()
		"join":
			sim.ensure_player(a[0])
		"grant":
			var items: Dictionary = a[1]
			for id: String in items:
				sim.inv_add(a[0], db.item_index(StringName(id)), int(items[id]))
			items_gained.emit(a[0], items)
	_check_zones()
	inventory_changed.emit()


## 부하 시험용 공장. 비용 없이 짓고 발전기에 연료를 채워 둔다. 모든 피어에서 같은 결과가 나온다.
func _apply_stress(lines: int) -> void:
	var z := DEV_STRESS_ZONE
	if sim.ground_y(z[0], z[1]) == SimWorld.NO_GROUND:
		sim.add_build_zone(z[0], z[1], z[2], z[3], z[4])
	var cols := z[2] / 16
	var fuel := Registry.db.item_index(&"biofuel")
	for i in lines:
		var origin := Vector3i(z[0] + 2 + (i % cols) * 16, z[4], z[1] + (i / cols) * 24)
		if sim.occupancy.has(origin + (ReferenceLine.MACHINES[0][1] as Vector3i)):
			continue
		sim.add_node(origin + ReferenceLine.NODE_CELL, &"iron_ore")
		for m in ReferenceLine.MACHINES:
			var s := sim.place(m[0], origin + (m[1] as Vector3i), 0, "dev")
			if s != null and s.kind == StructureDef.Kind.GENERATOR:
				s.fuel_item = fuel
				s.fuel_count = int(s.def.params.get("fuel_cap", 10))
		for b in ReferenceLine.BELTS.size():
			sim.place_belt(&"belt", ReferenceLine.belt_path(origin, b), "dev")


func _added(s: SimStructure) -> void:
	if s != null:
		structure_added.emit(s)


func _named(items: Dictionary[int, int]) -> Dictionary:
	var out := {}
	for item: int in items:
		out[String(Registry.db.item_ids[item])] = items[item]
	return out


@rpc("authority", "call_remote", "reliable")
func _ev_rejected(reason: String) -> void:
	request_rejected.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _ev_checksum(tick: int, host_hash: String) -> void:
	if not running:
		return
	_advance_to(tick)
	if sim.tick_count != tick or sim.state_hash() != host_hash:
		push_warning("[World] 틱 %d에서 호스트와 상태가 다름. 스냅샷을 다시 받는다." % tick)
		resync_count += 1
		running = false
		desynced.emit(tick)
		_req_resync.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _req_resync() -> void:
	if multiplayer.is_server():
		var sender := multiplayer.get_remote_sender_id()
		if Net.players.has(sender):
			_synced.erase(sender)
			send_snapshot(sender)


# ---------------------------------------------------------------------------
# 스냅샷: 중도 참가와 재동기화. 저장 파일과 같은 직렬화를 쓴다.
# ---------------------------------------------------------------------------

func send_snapshot(peer_id: int) -> void:
	var raw := var_to_bytes(sim.to_dict())
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var count := ceili(float(packed.size()) / SNAPSHOT_CHUNK)
	_snap_begin.rpc_id(peer_id, raw.size(), count)
	for i in count:
		_snap_chunk.rpc_id(peer_id, i, packed.slice(i * SNAPSHOT_CHUNK, (i + 1) * SNAPSHOT_CHUNK))
	# 신뢰성 채널은 순서를 지키므로, 이 뒤에 보내는 이벤트는 스냅샷 다음에 도착한다.
	if not _synced.has(peer_id):
		_synced.append(peer_id)


@rpc("authority", "call_remote", "reliable")
func _snap_begin(raw_size: int, count: int) -> void:
	_snapshot_size = raw_size
	_snapshot_parts.clear()
	_snapshot_parts.resize(count)


@rpc("authority", "call_remote", "reliable")
func _snap_chunk(index: int, data: PackedByteArray) -> void:
	if index < 0 or index >= _snapshot_parts.size():
		return
	_snapshot_parts[index] = data
	if index < _snapshot_parts.size() - 1:
		return
	var packed := PackedByteArray()
	for part in _snapshot_parts:
		packed.append_array(part)
	_snapshot_parts.clear()
	var parsed: Variant = bytes_to_var(packed.decompress(_snapshot_size, FileAccess.COMPRESSION_ZSTD))
	var loaded: SimWorld = SimWorld.from_dict(Registry.db, parsed) if parsed is Dictionary else null
	if loaded == null:
		push_error("[World] 스냅샷을 읽을 수 없음")
		Net.leave()
		return
	sim = loaded
	_target_tick = sim.tick_count
	_accum = 0.0
	running = true
	reset.emit()
	Net.notify_snapshot_applied()


# ---------------------------------------------------------------------------
# 플레이어 위치: 본인이 권한을 갖고 보고한다. 호스트는 말이 안 되는 값만 걸러 중계한다.
# ---------------------------------------------------------------------------

func send_player_state(pos: Vector3, yaw: float, pitch: float, crouch: bool) -> void:
	if not running:
		return
	positions[multiplayer.get_unique_id()] = pos
	yaws[multiplayer.get_unique_id()] = yaw
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if multiplayer.is_server():
		for p in _synced:
			_ev_player.rpc_id(p, 1, pos, yaw, pitch, crouch)
	else:
		_req_player.rpc_id(1, pos, yaw, pitch, crouch)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _req_player(pos: Vector3, yaw: float, pitch: float, crouch: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _synced.has(sender) or not pos.is_finite() or not is_finite(yaw) or not is_finite(pitch):
		return
	if absf(pos.x) > MAX_COORD or absf(pos.y) > MAX_COORD or absf(pos.z) > MAX_COORD:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if positions.has(sender):
		var dt := maxf(now - _last_player_time[sender], 0.05)
		if pos.distance_to(positions[sender]) / dt > MAX_PLAYER_SPEED:
			return
	positions[sender] = pos
	yaws[sender] = yaw
	_last_player_time[sender] = now
	remote_player_state.emit(sender, pos, yaw, pitch, crouch)
	for p in _synced:
		if p != sender:
			_ev_player.rpc_id(p, sender, pos, yaw, pitch, crouch)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_player(peer_id: int, pos: Vector3, yaw: float, pitch: float, crouch: bool) -> void:
	positions[peer_id] = pos
	remote_player_state.emit(peer_id, pos, yaw, pitch, crouch)


# ---------------------------------------------------------------------------

func _cell_ok(c: Vector3i) -> bool:
	return absi(c.x) <= MAX_COORD and absi(c.y) <= MAX_COORD and absi(c.z) <= MAX_COORD


func _flatten(path: Array[Vector3i]) -> PackedInt32Array:
	var flat := PackedInt32Array()
	for c in path:
		flat.append(c.x)
		flat.append(c.y)
		flat.append(c.z)
	return flat


func _unflatten(flat: PackedInt32Array) -> Array[Vector3i]:
	var path: Array[Vector3i] = []
	for i in range(0, flat.size(), 3):
		path.append(Vector3i(flat[i], flat[i + 1], flat[i + 2]))
	return path
