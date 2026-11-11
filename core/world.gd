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
signal remote_player_state(peer_id: int, pos: Vector3, yaw: float, pitch: float, crouch: bool)

const TICK_SECONDS := 0.1
const CHECKSUM_INTERVAL := 100
const SNAPSHOT_CHUNK := 60000
const MAX_COORD := 1000000
const MAX_BELT_CELLS := 256
const MAX_PLAYER_SPEED := 40.0   ## m/s. 이보다 빠른 이동 보고는 무시한다.
## 개발용 월드의 광맥 자리(기준 생산 라인의 원점). 실제 맵이 생기면 맵 데이터로 대체한다.
const DEV_LINE_ORIGINS: Array[Vector3i] = [
	Vector3i(-24, 0, -45), Vector3i(-8, 0, -45), Vector3i(8, 0, -45), Vector3i(24, 0, -45),
]

var sim: SimWorld
var running: bool = false
var resync_count: int = 0

var _accum: float = 0.0
var _target_tick: int = 0
var _synced: Array[int] = []                       ## 호스트: 스냅샷을 받은 피어
var _snapshot_parts: Array[PackedByteArray] = []   ## 클라이언트: 받는 중인 스냅샷
var _snapshot_size: int = 0
var _last_player_pos: Dictionary[int, Vector3] = {}
var _last_player_time: Dictionary[int, float] = {}


func start_new() -> void:
	sim = SimWorld.new(Registry.db)
	for origin in DEV_LINE_ORIGINS:
		sim.add_node(origin + ReferenceLine.NODE_CELL, &"iron_ore")
	_synced.clear()
	_accum = 0.0
	running = true
	reset.emit()


func stop() -> void:
	running = false
	_synced.clear()
	_snapshot_parts.clear()


func forget_peer(peer_id: int) -> void:
	_synced.erase(peer_id)
	_last_player_pos.erase(peer_id)
	_last_player_time.erase(peer_id)


## 틱과 틱 사이의 진행 비율(0..1). 화면 보간용.
func tick_fraction() -> float:
	return clampf(_accum / TICK_SECONDS, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	if not running:
		return
	_accum += delta
	if multiplayer.is_server():
		while _accum >= TICK_SECONDS:
			_accum -= TICK_SECONDS
			sim.tick()
			for p in _synced:
				_ev_tick.rpc_id(p, sim.tick_count)
			if sim.tick_count % CHECKSUM_INTERVAL == 0 and not _synced.is_empty():
				var h := sim.state_hash()
				for p in _synced:
					_ev_checksum.rpc_id(p, sim.tick_count, h)
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
	_accum = 0.0
	ticked.emit(sim.tick_count)


func _advance_to(tick: int) -> void:
	while sim.tick_count < tick:
		_tick_client()
	_target_tick = maxi(_target_tick, tick)


# ---------------------------------------------------------------------------
# 요청 (누구나 → 호스트). 호스트 자신의 입력도 같은 검증을 거친다.
# ---------------------------------------------------------------------------

func request_place(def_id: StringName, cell: Vector3i, rot: int) -> void:
	if multiplayer.is_server():
		_do_place(1, String(def_id), cell, rot)
	else:
		_req_place.rpc_id(1, String(def_id), cell, rot)


func request_place_belt(def_id: StringName, path: Array[Vector3i], dir: int = -1) -> void:
	var flat := _flatten(path)
	if multiplayer.is_server():
		_do_place_belt(1, String(def_id), flat, dir)
	else:
		_req_place_belt.rpc_id(1, String(def_id), flat, dir)


func request_remove(id: int) -> void:
	if multiplayer.is_server():
		_do_remove(1, id)
	else:
		_req_remove.rpc_id(1, id)


## 칸에 있는 구조물에 아이템을 넣는다. 인벤토리가 생기기 전까지는 수량 검사가 없다(M2에서 추가).
func request_insert_at(cell: Vector3i, item_id: StringName, count: int) -> void:
	if multiplayer.is_server():
		_do_insert(1, cell, String(item_id), count)
	else:
		_req_insert.rpc_id(1, cell, String(item_id), count)


@rpc("any_peer", "call_remote", "reliable")
func _req_place(def_id: String, cell: Vector3i, rot: int) -> void:
	if multiplayer.is_server():
		_do_place(multiplayer.get_remote_sender_id(), def_id, cell, rot)


@rpc("any_peer", "call_remote", "reliable")
func _req_place_belt(def_id: String, flat: PackedInt32Array, dir: int) -> void:
	if multiplayer.is_server():
		_do_place_belt(multiplayer.get_remote_sender_id(), def_id, flat, dir)


@rpc("any_peer", "call_remote", "reliable")
func _req_remove(id: int) -> void:
	if multiplayer.is_server():
		_do_remove(multiplayer.get_remote_sender_id(), id)


@rpc("any_peer", "call_remote", "reliable")
func _req_insert(cell: Vector3i, item_id: String, count: int) -> void:
	if multiplayer.is_server():
		_do_insert(multiplayer.get_remote_sender_id(), cell, item_id, count)


func _do_place(sender: int, def_id: String, cell: Vector3i, rot: int) -> void:
	if not Net.may_build(sender):
		return _reject(sender, "no_permission")
	if not _cell_ok(cell) or rot < 0 or rot > 3:
		return _reject(sender, "bad_request")
	var why := sim.can_place(StringName(def_id), cell, rot)
	if why != "":
		return _reject(sender, why)
	var id := sim.next_id
	var by := _player_key(sender)
	_apply_place(def_id, cell, rot, by, id)
	for p in _synced:
		_ev_place.rpc_id(p, sim.tick_count, def_id, cell, rot, by, id)


func _do_place_belt(sender: int, def_id: String, flat: PackedInt32Array, dir: int) -> void:
	if not Net.may_build(sender):
		return _reject(sender, "no_permission")
	if flat.size() % 3 != 0 or flat.size() > MAX_BELT_CELLS * 3 or dir < -1 or dir > 3:
		return _reject(sender, "bad_request")
	var path := _unflatten(flat)
	for c in path:
		if not _cell_ok(c):
			return _reject(sender, "bad_request")
	var def: StructureDef = Registry.db.structures.get(StringName(def_id))
	if def == null or def.kind != StructureDef.Kind.BELT:
		return _reject(sender, "unknown_structure")
	var why := sim.can_place_belt(path, dir)
	if why != "":
		return _reject(sender, why)
	var id := sim.next_id
	var by := _player_key(sender)
	_apply_place_belt(def_id, flat, dir, by, id)
	for p in _synced:
		_ev_place_belt.rpc_id(p, sim.tick_count, def_id, flat, dir, by, id)


func _do_remove(sender: int, id: int) -> void:
	if not Net.may_build(sender):
		return _reject(sender, "no_permission")
	if not sim.structures.has(id):
		return _reject(sender, "not_found")
	_apply_remove(id)
	for p in _synced:
		_ev_remove.rpc_id(p, sim.tick_count, id)


func _do_insert(sender: int, cell: Vector3i, item_id: String, count: int) -> void:
	if not _cell_ok(cell) or count <= 0 or count > 1000:
		return _reject(sender, "bad_request")
	var id: int = sim.occupancy.get(cell, 0)
	if id == 0 or Registry.db.item_index(StringName(item_id)) < 0:
		return _reject(sender, "not_found")
	var accepted := sim.insert(id, StringName(item_id), count)
	if accepted <= 0:
		return _reject(sender, "full")
	for p in _synced:
		_ev_insert.rpc_id(p, sim.tick_count, id, item_id, accepted)


func _reject(sender: int, reason: String) -> void:
	if sender == 1:
		request_rejected.emit(reason)
	else:
		_ev_rejected.rpc_id(sender, reason)


func _player_key(peer_id: int) -> String:
	# Steam 연동 전까지는 접속 이름을 쓴다. 이후 Steam ID로 바꾼다.
	return str((Net.players.get(peer_id, {}) as Dictionary).get("name", "p%d" % peer_id))


# ---------------------------------------------------------------------------
# 이벤트 (호스트 → 클라이언트). 첫 인자는 호스트가 그 일을 적용한 틱이다.
# ---------------------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func _ev_tick(tick: int) -> void:
	if running:
		_target_tick = maxi(_target_tick, tick)


@rpc("authority", "call_remote", "reliable")
func _ev_place(tick: int, def_id: String, cell: Vector3i, rot: int, by: String, id: int) -> void:
	if running:
		_advance_to(tick)
		_apply_place(def_id, cell, rot, by, id)


@rpc("authority", "call_remote", "reliable")
func _ev_place_belt(tick: int, def_id: String, flat: PackedInt32Array, dir: int, by: String, id: int) -> void:
	if running:
		_advance_to(tick)
		_apply_place_belt(def_id, flat, dir, by, id)


@rpc("authority", "call_remote", "reliable")
func _ev_remove(tick: int, id: int) -> void:
	if running:
		_advance_to(tick)
		_apply_remove(id)


@rpc("authority", "call_remote", "reliable")
func _ev_insert(tick: int, id: int, item_id: String, count: int) -> void:
	if running:
		_advance_to(tick)
		sim.insert(id, StringName(item_id), count)


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


func _apply_place(def_id: String, cell: Vector3i, rot: int, by: String, id: int) -> void:
	var s := sim.place(StringName(def_id), cell, rot, by, id)
	if s != null:
		structure_added.emit(s)


func _apply_place_belt(def_id: String, flat: PackedInt32Array, dir: int, by: String, id: int) -> void:
	var s := sim.place_belt(StringName(def_id), _unflatten(flat), by, dir, id)
	if s != null:
		structure_added.emit(s)


func _apply_remove(id: int) -> void:
	if sim.remove(id) != null:
		structure_removed.emit(id)


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
	if _last_player_pos.has(sender):
		var dt := maxf(now - _last_player_time[sender], 0.05)
		if pos.distance_to(_last_player_pos[sender]) / dt > MAX_PLAYER_SPEED:
			return
	_last_player_pos[sender] = pos
	_last_player_time[sender] = now
	remote_player_state.emit(sender, pos, yaw, pitch, crouch)
	for p in _synced:
		if p != sender:
			_ev_player.rpc_id(p, sender, pos, yaw, pitch, crouch)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_player(peer_id: int, pos: Vector3, yaw: float, pitch: float, crouch: bool) -> void:
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
