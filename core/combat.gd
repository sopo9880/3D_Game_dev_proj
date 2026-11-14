extends Node
## 오토로드. 전투 상태의 유일한 변경 창구: 플레이어 체력, 적, 투사체, 전리품.
##
## 호스트가 전부 판정한다. 클라이언트는 "내가 이 적을 맞혔다"고 보고할 뿐이고(D-005),
## 호스트가 무기·연사 속도·거리·생존 여부를 확인한 뒤 피해를 계산한다.
## 적은 호스트에서만 생각하고, 클라이언트에는 위치와 체력을 10Hz로 보낸다.

signal vitals_changed(peer_id: int)
signal respawned(pos: Vector3)                           ## 내 캐릭터가 다시 태어났다
signal enemy_died(id: int, pos: Vector3, killer: int)
signal shot_seen(peer_id: int, weapon_id: StringName, from: Vector3, to: Vector3)
signal projectile_spawned(id: int, kind: StringName, pos: Vector3, vel: Vector3)
signal projectile_ended(id: int, pos: Vector3, exploded: bool)
signal grenades_changed
signal hazard_spawned(pos: Vector3, radius: float, delay: float)   ## 바닥 표시 뒤 폭발하는 위험 지대

enum PState { ALIVE, DOWNED }

const ENEMY_SEND_INTERVAL := 0.1
const VITALS_SEND_INTERVAL := 0.25
const SPIT_LIFETIME := 3.0
const SPIT_HIT_RADIUS := 0.6
const GRENADE_FUSE := 2.0
const GRENADE_GRAVITY := 18.0
const LOOT_RANGE := 60.0
const MAX_ENEMIES := 14


class Vitals:
	var hp: float = CombatRules.MAX_HP
	var state: int = PState.ALIVE
	var down_left: float = 0.0
	var since_damage: float = 99.0


class Projectile:
	var id: int
	var kind: StringName
	var pos: Vector3
	var vel: Vector3
	var damage: float
	var age: float = 0.0
	var owner_peer: int = 0


class Hazard:
	var pos: Vector3
	var radius: float
	var left: float
	var damage: float


class SpawnPoint:
	var pos: Vector3
	var type_id: StringName
	var turret: bool = false
	var cooldown: float = 0.0
	var alive: Array[int] = []


## 적이 나오는 구역 하나(출현 지점들과 우두머리의 터).
class ZoneState:
	var zone: int = -1                 ## 구역 인덱스(복원 진행도에 따라 적이 줄어든다)
	var requires: int = -1             ## 이 구역이 복원되기 전에는 적이 나오지 않는다(입구가 막혀 있다)
	var points: Array[SpawnPoint] = []
	var boss_id: StringName = &""
	var boss_spawn: Vector3 = Vector3.ZERO
	var boss_radius: float = 0.0
	var boss: Enemy = null
	var boss_alone: float = 0.0


var vitals: Dictionary[int, Vitals] = {}
var my_grenades: int = CombatRules.GRENADE_MAX
var enemies: Dictionary[int, Enemy] = {}
var enemy_defs: Array[EnemyDef] = []
var weapons: Dictionary[StringName, WeaponDef] = {}

## 호스트 설정
var auto_spawn: bool = true
var spawn_delay: float = 45.0
var activation_range: float = 45.0   ## 플레이어가 출현 지점에서 이 안에 있을 때만 적이 나온다

## 점검용 집계
var rejected_shots: int = 0
var kills: int = 0

var _scene: Node3D
var _nav_map: RID
var _spawn: Vector3 = Vector3.ZERO
var _zones: Array[ZoneState] = []
var _enemy_slot: Dictionary[int, int] = {}   ## 적 ID → 그 적이 속한 구역의 순번(_zones의 인덱스)
var _hazards: Array[Hazard] = []
var _local_body: RID
var _next_enemy_id: int = 1
var _next_projectile_id: int = 1
var _projectiles: Array[Projectile] = []
var _grenades: Dictionary[int, int] = {}
var _last_shot: Dictionary[int, float] = {}
var _last_melee: Dictionary[int, float] = {}
var _enemy_timer: float = 0.0
var _vitals_timer: float = 0.0
var _hit_weapon: StringName = &""
var _hit_ids: PackedInt32Array = []
var _hit_heads: PackedInt32Array = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	enemy_defs = EnemyDef.load_all("res://data/enemies.json")
	for w in WeaponDef.load_all("res://data/weapons.json"):
		weapons[w.id] = w
	_rng.randomize()
	Net.players_changed.connect(_sync_players)
	Net.disconnected.connect(func(_reason: String) -> void: unbind_scene())


# ---------------------------------------------------------------------------
# 씬 연결: 전투가 벌어지는 맵이 자신을 등록한다.
# ---------------------------------------------------------------------------

## config: {"zones": [{"zone": int, "spawn_points": Array[Vector3], "spawn_types": Array[StringName],
##                     "requires": int, "boss": StringName, "boss_spawn": Vector3, "boss_radius": float}, ...]}
func bind_scene(scene: Node3D, spawn: Vector3, nav_map: RID, config: Dictionary, local_body: RID) -> void:
	unbind_scene()
	_scene = scene
	_spawn = spawn
	_nav_map = nav_map
	_local_body = local_body
	for row: Dictionary in config.get("zones", []):
		var zs := ZoneState.new()
		zs.zone = int(row.get("zone", -1))
		zs.requires = int(row.get("requires", -1))
		zs.boss_id = row.get("boss", &"")
		zs.boss_spawn = row.get("boss_spawn", Vector3.ZERO)
		zs.boss_radius = float(row.get("boss_radius", 0.0))
		var types: Array = row.get("spawn_types", [])
		var points: Array = row.get("spawn_points", [])
		for i in points.size():
			if types.is_empty():
				break
			var sp := SpawnPoint.new()
			sp.pos = points[i]
			sp.type_id = types[i % types.size()]   # 종류를 번갈아
			var d := enemy_def(sp.type_id)
			sp.turret = d != null and d.kind == &"turret"
			zs.points.append(sp)
		_zones.append(zs)
	_sync_players()
	my_grenades = CombatRules.GRENADE_MAX
	grenades_changed.emit()


func unbind_scene() -> void:
	for id: int in enemies:
		if is_instance_valid(enemies[id]):
			enemies[id].queue_free()
	enemies.clear()
	_projectiles.clear()
	_zones.clear()
	_enemy_slot.clear()
	_hazards.clear()
	_scene = null
	vitals.clear()
	_grenades.clear()


func is_bound() -> bool:
	return _scene != null and is_instance_valid(_scene)


func my_vitals() -> Vitals:
	return vitals.get(multiplayer.get_unique_id())


func is_alive(peer_id: int) -> bool:
	var v: Vitals = vitals.get(peer_id)
	return v != null and v.state == PState.ALIVE


func _sync_players() -> void:
	for peer: int in Net.players:
		if not vitals.has(peer):
			vitals[peer] = Vitals.new()
			_grenades[peer] = CombatRules.GRENADE_MAX
	for peer: int in vitals.keys():
		if not Net.players.has(peer):
			vitals.erase(peer)
			_grenades.erase(peer)
			_last_shot.erase(peer)
			_last_melee.erase(peer)


# ---------------------------------------------------------------------------
# 호스트 틱
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not is_bound() or not World.running:
		return
	if not multiplayer.is_server():
		return
	_update_vitals(delta)
	_update_projectiles(delta)
	_update_hazards(delta)
	if auto_spawn:
		_update_spawner(delta)
	_enemy_timer += delta
	if _enemy_timer >= ENEMY_SEND_INTERVAL:
		_enemy_timer = 0.0
		_broadcast_enemies()
	_vitals_timer += delta
	if _vitals_timer >= VITALS_SEND_INTERVAL:
		_vitals_timer = 0.0
		_broadcast_vitals(false)


func _process(_delta: float) -> void:
	_flush_hits()


# ---------------------------------------------------------------------------
# 체력, 쓰러짐, 부활
# ---------------------------------------------------------------------------

func _update_vitals(delta: float) -> void:
	var alive_count := 0
	for peer: int in vitals:
		if vitals[peer].state == PState.ALIVE:
			alive_count += 1
	for peer: int in vitals:
		var v := vitals[peer]
		if v.state == PState.ALIVE:
			v.since_damage += delta
			if v.since_damage >= CombatRules.REGEN_DELAY and v.hp < CombatRules.MAX_HP:
				v.hp = minf(v.hp + CombatRules.REGEN_PER_SECOND * delta, CombatRules.MAX_HP)
		else:
			# 일으켜 줄 사람이 아무도 없으면 오래 기다리게 하지 않는다.
			if alive_count == 0:
				v.down_left = minf(v.down_left, CombatRules.SOLO_RESPAWN_SECONDS)
			v.down_left -= delta
			if v.down_left <= 0.0:
				_respawn(peer)


## 호스트: 플레이어에게 피해를 준다.
func damage_player(peer: int, amount: float) -> void:
	if not multiplayer.is_server():
		return
	var v: Vitals = vitals.get(peer)
	if v == null or v.state != PState.ALIVE or amount <= 0.0:
		return
	v.hp -= amount * float(World.difficulty_mult()[1])
	v.since_damage = 0.0
	if v.hp <= 0.0:
		v.hp = 0.0
		v.state = PState.DOWNED
		v.down_left = CombatRules.DOWN_SECONDS
	_broadcast_vitals(true)


func _respawn(peer: int) -> void:
	var v := vitals[peer]
	v.hp = CombatRules.MAX_HP
	v.state = PState.ALIVE
	v.since_damage = 99.0
	_grenades[peer] = CombatRules.GRENADE_MAX
	World.positions[peer] = _spawn
	_broadcast_vitals(true)
	if peer == 1:
		_ev_respawn(_spawn, CombatRules.GRENADE_MAX)
	else:
		_ev_respawn.rpc_id(peer, _spawn, CombatRules.GRENADE_MAX)


@rpc("authority", "call_remote", "reliable")
func _ev_respawn(pos: Vector3, grenade_count: int) -> void:
	my_grenades = grenade_count
	grenades_changed.emit()
	respawned.emit(pos)


## 쓰러진 동료를 일으킨다(가까이에서 일정 시간 버틴 뒤 클라이언트가 부른다).
func request_revive(target: int) -> void:
	if multiplayer.is_server():
		_do_revive(1, target)
	else:
		_req_revive.rpc_id(1, target)


@rpc("any_peer", "call_remote", "reliable")
func _req_revive(target: int) -> void:
	if multiplayer.is_server():
		_do_revive(multiplayer.get_remote_sender_id(), target)


func _do_revive(sender: int, target: int) -> void:
	var v: Vitals = vitals.get(target)
	if v == null or v.state != PState.DOWNED or sender == target or not is_alive(sender):
		return
	if not World.positions.has(sender) or not World.positions.has(target):
		return
	if World.positions[sender].distance_to(World.positions[target]) > CombatRules.REVIVE_RANGE + 1.0:
		return
	v.state = PState.ALIVE
	v.hp = CombatRules.REVIVE_HP
	v.since_damage = 0.0
	_broadcast_vitals(true)


func _broadcast_vitals(reliable: bool) -> void:
	var peers := PackedInt32Array()
	var hps := PackedFloat32Array()
	var states := PackedInt32Array()
	var downs := PackedFloat32Array()
	for peer: int in vitals:
		var v := vitals[peer]
		peers.append(peer)
		hps.append(v.hp)
		states.append(v.state)
		downs.append(v.down_left)
	for p in World.synced_peers():
		if reliable:
			_ev_vitals_now.rpc_id(p, peers, hps, states, downs)
		else:
			_ev_vitals.rpc_id(p, peers, hps, states, downs)
	for peer: int in vitals:
		vitals_changed.emit(peer)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_vitals(peers: PackedInt32Array, hps: PackedFloat32Array, states: PackedInt32Array, downs: PackedFloat32Array) -> void:
	_apply_vitals(peers, hps, states, downs)


@rpc("authority", "call_remote", "reliable")
func _ev_vitals_now(peers: PackedInt32Array, hps: PackedFloat32Array, states: PackedInt32Array, downs: PackedFloat32Array) -> void:
	_apply_vitals(peers, hps, states, downs)


func _apply_vitals(peers: PackedInt32Array, hps: PackedFloat32Array, states: PackedInt32Array, downs: PackedFloat32Array) -> void:
	for i in peers.size():
		var v: Vitals = vitals.get(peers[i])
		if v == null:
			v = Vitals.new()
			vitals[peers[i]] = v
		v.hp = hps[i]
		v.state = states[i]
		v.down_left = downs[i]
		vitals_changed.emit(peers[i])


## 살아 있는 플레이어 중 가장 가까운 사람. [피어 ID, 위치], 없으면 [-1, Vector3.ZERO].
func nearest_alive_player(from: Vector3, max_range: float) -> Array:
	var best := -1
	var best_dist := max_range
	var best_pos := Vector3.ZERO
	for peer: int in vitals:
		if vitals[peer].state != PState.ALIVE or not World.positions.has(peer):
			continue
		var d := from.distance_to(World.positions[peer])
		if d < best_dist:
			best = peer
			best_dist = d
			best_pos = World.positions[peer]
	return [best, best_pos]


# ---------------------------------------------------------------------------
# 사격 보고와 검증
# ---------------------------------------------------------------------------

## 플레이어가 한 번 쏠 때 부른다. 이어서 오는 queue_hit들이 이 무기의 탄환으로 묶인다.
func begin_shot(weapon_id: StringName, from: Vector3, to: Vector3) -> void:
	_flush_hits()
	_hit_weapon = weapon_id
	if not is_bound():
		return
	if multiplayer.is_server():
		for p in World.synced_peers():
			_ev_shot.rpc_id(p, 1, String(weapon_id), from, to)
	elif World.running:
		_req_shot.rpc_id(1, String(weapon_id), from, to)


func queue_hit(enemy_id: int, head: bool) -> void:
	_hit_ids.append(enemy_id)
	_hit_heads.append(1 if head else 0)


func _flush_hits() -> void:
	if _hit_ids.is_empty():
		return
	var ids := _hit_ids
	var heads := _hit_heads
	_hit_ids = PackedInt32Array()
	_hit_heads = PackedInt32Array()
	if multiplayer.is_server():
		_do_hits(1, String(_hit_weapon), ids, heads)
	elif World.running:
		_req_hits.rpc_id(1, String(_hit_weapon), ids, heads)


@rpc("any_peer", "call_remote", "unreliable")
func _req_shot(weapon_id: String, from: Vector3, to: Vector3) -> void:
	if not multiplayer.is_server() or not from.is_finite() or not to.is_finite():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not is_alive(sender) or not weapons.has(StringName(weapon_id)):
		return
	shot_seen.emit(sender, StringName(weapon_id), from, to)
	for p in World.synced_peers():
		if p != sender:
			_ev_shot.rpc_id(p, sender, weapon_id, from, to)


@rpc("authority", "call_remote", "unreliable")
func _ev_shot(peer: int, weapon_id: String, from: Vector3, to: Vector3) -> void:
	shot_seen.emit(peer, StringName(weapon_id), from, to)


@rpc("any_peer", "call_remote", "reliable")
func _req_hits(weapon_id: String, ids: PackedInt32Array, heads: PackedInt32Array) -> void:
	if multiplayer.is_server():
		_do_hits(multiplayer.get_remote_sender_id(), weapon_id, ids, heads)


func _do_hits(sender: int, weapon_id: String, ids: PackedInt32Array, heads: PackedInt32Array) -> void:
	if not is_bound() or ids.size() != heads.size():
		return
	var def: WeaponDef = weapons.get(StringName(weapon_id))
	var now := Time.get_ticks_msec() / 1000.0
	var why := CombatRules.check_shot(def, ids.size(), now - float(_last_shot.get(sender, -99.0)))
	if why == "" and (not is_alive(sender) or not World.positions.has(sender)):
		why = "not_alive"
	if why != "":
		rejected_shots += 1
		return
	_last_shot[sender] = now
	var from := World.positions[sender]
	for i in ids.size():
		var e: Enemy = enemies.get(ids[i])
		if e == null or e.hp <= 0.0:
			continue
		var dist := from.distance_to(e.global_position)
		if dist > CombatRules.MAX_HIT_DISTANCE:
			continue
		_damage_enemy(e, CombatRules.hit_damage(def, dist, heads[i] != 0), sender)


## 근접 공격이 맞았다고 보고한다.
func report_melee(enemy_ids: PackedInt32Array) -> void:
	if not is_bound():
		return
	if multiplayer.is_server():
		_do_melee(1, enemy_ids)
	elif World.running:
		_req_melee.rpc_id(1, enemy_ids)


@rpc("any_peer", "call_remote", "reliable")
func _req_melee(enemy_ids: PackedInt32Array) -> void:
	if multiplayer.is_server():
		_do_melee(multiplayer.get_remote_sender_id(), enemy_ids)


func _do_melee(sender: int, enemy_ids: PackedInt32Array) -> void:
	if not is_bound():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var why := CombatRules.check_melee(enemy_ids.size(), now - float(_last_melee.get(sender, -99.0)))
	if why == "" and (not is_alive(sender) or not World.positions.has(sender)):
		why = "not_alive"
	if why != "":
		rejected_shots += 1
		return
	_last_melee[sender] = now
	var from := World.positions[sender]
	for id in enemy_ids:
		var e: Enemy = enemies.get(id)
		if e == null or e.hp <= 0.0 or from.distance_to(e.global_position) > CombatRules.MELEE_MAX_DISTANCE:
			continue
		e.stagger(e.global_position - from)
		_damage_enemy(e, CombatRules.MELEE_DAMAGE, sender)


func _damage_enemy(e: Enemy, amount: float, by: int) -> void:
	# 약점이 드러난 우두머리는 두 배로 아프다.
	e.hp -= amount * (2.0 if e.stunned else 1.0)
	e.on_damaged()
	if e.def.kind == &"boss" and e.hp > 0.0:
		# 체력 66%, 33%에서 한 번씩 졸개를 부른다.
		var frac := e.hp / e.max_hp
		while e.summons_done < 2 and frac <= [0.66, 0.33][e.summons_done]:
			e.summons_done += 1
			for i in int(e.def.summon_count):
				var a := TAU * i / e.def.summon_count
				spawn_enemy(e.def.summon_type, e.global_position + Vector3(cos(a), 0, sin(a)) * 4.0 + Vector3(0, 0.2, 0),
						int(_enemy_slot.get(e.net_id, -1)))
	if e.hp > 0.0:
		return
	for zs in _zones:
		if e == zs.boss:
			zs.boss = null
			# 구역이 복원되어 사라지는 것은 처치가 아니다.
			if by > 0:
				var witnesses: Array[int] = []
				for peer: int in vitals:
					if peer == by or (World.positions.has(peer) and World.positions[peer].distance_to(e.global_position) <= LOOT_RANGE):
						witnesses.append(peer)
				World.report_boss_defeated(zs.zone, witnesses)
		for sp in zs.points:
			sp.alive.erase(e.net_id)
	var pos := e.global_position
	enemies.erase(e.net_id)
	_enemy_slot.erase(e.net_id)
	kills += 1
	# 전리품은 플레이어마다 따로 굴린다.
	for peer: int in vitals:
		if peer == by or (World.positions.has(peer) and World.positions[peer].distance_to(pos) <= LOOT_RANGE):
			_grant(peer, CombatRules.roll_loot(e.def.loot, _rng))
	for p in World.synced_peers():
		_ev_enemy_died.rpc_id(p, e.net_id, pos, by)
	enemy_died.emit(e.net_id, pos, by)
	e.queue_free()


@rpc("authority", "call_remote", "reliable")
func _ev_enemy_died(id: int, pos: Vector3, killer: int) -> void:
	var e: Enemy = enemies.get(id)
	if e != null:
		enemies.erase(id)
		e.queue_free()
	enemy_died.emit(id, pos, killer)


func _grant(peer: int, items: Dictionary) -> void:
	# 소지품은 월드 상태의 일부다(저장되고 모든 피어가 같은 값을 갖는다).
	World.grant(peer, items)


# ---------------------------------------------------------------------------
# 적 생성과 동기화
# ---------------------------------------------------------------------------

func enemy_def(type_id: StringName) -> EnemyDef:
	for d in enemy_defs:
		if d.id == type_id:
			return d
	return null


## 호스트: 적을 하나 만든다. slot은 그 적이 속한 구역의 순번(훈련장처럼 구역 밖이면 -1).
func spawn_enemy(type_id: StringName, pos: Vector3, slot: int = -1) -> Enemy:
	if not multiplayer.is_server() or not is_bound():
		return null
	for d in enemy_defs:
		if d.id == type_id:
			var players_near := 0
			for peer: int in vitals:
				if World.positions.has(peer) and World.positions[peer].distance_to(pos) <= activation_range:
					players_near += 1
			var hp := CombatRules.scaled_hp(d.hp, players_near) * float(World.difficulty_mult()[0])
			var e := _make_enemy(_next_enemy_id, d, hp, false)
			_next_enemy_id += 1
			e.position = pos
			if slot >= 0:
				_enemy_slot[e.net_id] = slot
			return e
	return null


func _make_enemy(id: int, def: EnemyDef, hp: float, puppet: bool) -> Enemy:
	var e := Enemy.new()
	e.setup(id, def, hp, puppet)
	enemies[id] = e
	_scene.add_child(e)
	return e


## 구역 복원이 진행될수록 한 지점에서 나오는 적이 줄고, 끝나면 더는 나오지 않는다.
## slot은 구역의 순번(맵 데이터의 zones 순서).
func spawn_cap(slot: int = 0) -> int:
	if slot < 0 or slot >= _zones.size():
		return 0
	var zs := _zones[slot]
	var progress := World.sim.zone_progress(zs.zone) if zs.zone >= 0 else 0
	if progress >= 100:
		return 0
	var cap := 3 if progress < 50 else (2 if progress < 80 else 1)
	# 다섯 명 이상이 함께 싸우면 체력만 올리지 않고 수도 늘린다.
	return cap + (1 if _players_in_zone(zs) >= 5 else 0)


## 지금 그 구역에서 싸우고 있는 인원(출현 지점 근처에 있는 살아 있는 플레이어).
func _players_in_zone(zs: ZoneState) -> int:
	var n := 0
	for peer: int in vitals:
		if vitals[peer].state != PState.ALIVE or not World.positions.has(peer):
			continue
		for sp in zs.points:
			if World.positions[peer].distance_to(sp.pos) <= 90.0:
				n += 1
				break
	return n


## 한 구역에 동시에 있을 수 있는 일반 적의 수.
func max_enemies(slot: int = 0) -> int:
	if slot < 0 or slot >= _zones.size():
		return MAX_ENEMIES
	return MAX_ENEMIES + 2 * maxi(_players_in_zone(_zones[slot]) - 4, 0)


func _update_spawner(delta: float) -> void:
	for slot in _zones.size():
		var zs := _zones[slot]
		if zs.requires >= 0 and not World.sim.zone_restored(zs.requires):
			continue
		var cap := spawn_cap(slot)
		if zs.zone >= 0 and cap == 0:
			# 복원이 끝났다: 이 구역에 남은 적은 사라진다.
			for id: int in enemies.keys():
				if int(_enemy_slot.get(id, -1)) == slot and enemies.has(id):
					_damage_enemy(enemies[id], 99999.0, 0)
			continue
		_update_boss(slot, delta)
		var limit := max_enemies(slot)
		var count := 0
		for sp in zs.points:
			count += sp.alive.size()
		for sp in zs.points:
			sp.cooldown = maxf(sp.cooldown - delta, 0.0)
			# 포탑은 한 자리에 하나만 선다.
			var point_cap := mini(cap, 1) if sp.turret else cap
			if sp.cooldown > 0.0 or sp.alive.size() >= point_cap or count >= limit:
				continue
			var near: int = nearest_alive_player(sp.pos, activation_range)[0]
			if near < 0:
				continue
			# 플레이어 코앞에는 나타나지 않는다.
			if World.positions[near].distance_to(sp.pos) < 12.0:
				continue
			var e := spawn_enemy(sp.type_id, sp.pos, slot)
			if e != null:
				sp.alive.append(e.net_id)
				sp.cooldown = spawn_delay
				count += 1


## 우두머리는 플레이어가 그 터에 들어오면 나타나고, 모두 떠나면 물러난다(체력이 처음으로 돌아간다).
func _update_boss(slot: int, delta: float) -> void:
	var zs := _zones[slot]
	if zs.zone < 0 or zs.boss_radius <= 0.0 or zs.boss_id == &"" or World.sim.boss_defeated(zs.zone):
		return
	if zs.boss == null or not is_instance_valid(zs.boss):
		zs.boss = null
		if nearest_alive_player(zs.boss_spawn, zs.boss_radius)[0] >= 0:
			zs.boss = spawn_enemy(zs.boss_id, zs.boss_spawn + Vector3(0, 0.2, 0), slot)
			zs.boss_alone = 0.0
		return
	if nearest_alive_player(zs.boss.global_position, 80.0)[0] >= 0:
		zs.boss_alone = 0.0
		return
	zs.boss_alone += delta
	if zs.boss_alone > 6.0:
		enemies.erase(zs.boss.net_id)
		_enemy_slot.erase(zs.boss.net_id)
		zs.boss.queue_free()
		zs.boss = null


func boss(slot: int = 0) -> Enemy:
	if slot < 0 or slot >= _zones.size():
		return null
	var b := _zones[slot].boss
	return b if b != null and is_instance_valid(b) else null


## 우두머리의 포격: 플레이어들의 발밑에 표시가 뜨고 잠시 뒤 터진다.
func boss_barrage(e: Enemy, target_peer: int) -> void:
	var spots: Array[Vector3] = []
	for peer: int in vitals:
		if is_alive(peer) and World.positions.has(peer) and World.positions[peer].distance_to(e.global_position) < 60.0:
			spots.append(World.positions[peer])
	# 표시는 항상 세 개: 사람이 적으면 노린 사람 주변에 더 놓는다.
	var center: Vector3 = World.positions.get(target_peer, e.global_position)
	while spots.size() < 3:
		var a := _rng.randf() * TAU
		spots.append(center + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(3.5, 6.0))
	for i in mini(spots.size(), 3):
		spawn_hazard(spots[i], e.def.barrage_radius, e.def.barrage_delay, e.def.barrage_damage)


## 우두머리의 고리 폭발: 몸 둘레와 그 바깥에 고리 두 겹이 차례로 터진다. 두 고리 사이나 더 바깥이 안전하다.
func boss_ring(e: Enemy) -> void:
	var n := int(e.def.ring_count)
	var start := _rng.randf() * TAU
	for ring in 2:
		var r := e.def.ring_radius * (1.0 + ring)
		var count := n * (1 + ring)
		for i in count:
			var a := start + TAU * i / count
			spawn_hazard(e.global_position + Vector3(cos(a), 0, sin(a)) * r, e.def.barrage_radius * 0.8,
					e.def.barrage_delay + 0.6 * ring, e.def.barrage_damage)


func spawn_hazard(pos: Vector3, radius: float, delay: float, damage: float) -> void:
	var h := Hazard.new()
	h.pos = pos
	h.radius = radius
	h.left = delay
	h.damage = damage
	_hazards.append(h)
	for p in World.synced_peers():
		_ev_hazard.rpc_id(p, pos, radius, delay)
	hazard_spawned.emit(pos, radius, delay)


@rpc("authority", "call_remote", "reliable")
func _ev_hazard(pos: Vector3, radius: float, delay: float) -> void:
	hazard_spawned.emit(pos, radius, delay)


func _update_hazards(delta: float) -> void:
	for h: Hazard in _hazards.duplicate():
		h.left -= delta
		if h.left > 0.0:
			continue
		_hazards.erase(h)
		for peer: int in vitals:
			if not is_alive(peer) or not World.positions.has(peer):
				continue
			var to := World.positions[peer] - h.pos
			if Vector2(to.x, to.z).length() <= h.radius and absf(to.y) < 3.0:
				damage_player(peer, h.damage)


func _broadcast_enemies() -> void:
	var peers := World.synced_peers()
	if peers.is_empty():
		return
	var ids := PackedInt32Array()
	var types := PackedInt32Array()
	var positions := PackedVector3Array()
	var yaws := PackedFloat32Array()
	var hps := PackedFloat32Array()
	var max_hps := PackedFloat32Array()
	var flags := PackedInt32Array()
	for id: int in enemies:
		var e := enemies[id]
		ids.append(id)
		types.append(e.def.index)
		positions.append(e.global_position)
		yaws.append(e.rotation.y)
		hps.append(e.hp)
		max_hps.append(e.max_hp)
		flags.append((1 if e.attacking else 0) | (2 if e.stunned else 0))
	for p in peers:
		_ev_enemies.rpc_id(p, ids, types, positions, yaws, hps, max_hps, flags)


@rpc("authority", "call_remote", "unreliable_ordered")
func _ev_enemies(ids: PackedInt32Array, types: PackedInt32Array, positions: PackedVector3Array,
		yaws: PackedFloat32Array, hps: PackedFloat32Array, max_hps: PackedFloat32Array, flags: PackedInt32Array) -> void:
	if not is_bound():
		return
	var seen: Dictionary[int, bool] = {}
	for i in ids.size():
		seen[ids[i]] = true
		var e: Enemy = enemies.get(ids[i])
		if e == null:
			if types[i] < 0 or types[i] >= enemy_defs.size():
				continue
			e = _make_enemy(ids[i], enemy_defs[types[i]], max_hps[i], true)
			e.position = positions[i]
		e.target_pos = positions[i]
		e.target_yaw = yaws[i]
		e.hp = hps[i]
		e.max_hp = max_hps[i]
		e.attacking = flags[i] & 1 != 0
		e.stunned = flags[i] & 2 != 0
	for id: int in enemies.keys():
		if not seen.has(id):
			enemies[id].queue_free()
			enemies.erase(id)


func find_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if not _nav_map.is_valid():
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(_nav_map, from, to, true)


## 두 점 사이에 지형이 가로막고 있지 않은가.
func has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	if not is_bound():
		return false
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	if _local_body.is_valid():
		q.exclude = [_local_body]
	return _scene.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ---------------------------------------------------------------------------
# 투사체: 원거리형의 침, 플레이어의 수류탄
# ---------------------------------------------------------------------------

## 적의 탄: 침(spit)과 포탑의 탄(bolt). 날아가는 규칙은 같고 보이는 모습만 다르다.
func spawn_spit(pos: Vector3, vel: Vector3, damage: float, kind: StringName = &"spit") -> void:
	_add_projectile(kind, pos, vel, damage, 0)


## 수류탄을 던진다(투척류 칸).
func request_throw(origin: Vector3, vel: Vector3) -> void:
	if my_grenades <= 0:
		return
	if multiplayer.is_server():
		_do_throw(1, origin, vel)
	else:
		_req_throw.rpc_id(1, origin, vel)


@rpc("any_peer", "call_remote", "reliable")
func _req_throw(origin: Vector3, vel: Vector3) -> void:
	if multiplayer.is_server():
		_do_throw(multiplayer.get_remote_sender_id(), origin, vel)


func _do_throw(sender: int, origin: Vector3, vel: Vector3) -> void:
	if not is_bound() or not is_alive(sender) or int(_grenades.get(sender, 0)) <= 0:
		return
	if not origin.is_finite() or not vel.is_finite() or vel.length() > CombatRules.GRENADE_MAX_SPEED:
		return
	if not World.positions.has(sender) or origin.distance_to(World.positions[sender]) > 4.0:
		return
	_grenades[sender] = int(_grenades[sender]) - 1
	_set_grenades(sender)
	_add_projectile(&"grenade", origin, vel, 0.0, sender)


## 보급: 투척류를 가득 채운다(개발용 보급 상자. 제작이 생기면 대체한다).
func request_resupply() -> void:
	if multiplayer.is_server():
		_do_resupply(1)
	else:
		_req_resupply.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _req_resupply() -> void:
	if multiplayer.is_server():
		_do_resupply(multiplayer.get_remote_sender_id())


func _do_resupply(sender: int) -> void:
	if _grenades.has(sender) and World.positions.has(sender) and World.positions[sender].distance_to(_spawn) < 15.0:
		_grenades[sender] = CombatRules.GRENADE_MAX
		_set_grenades(sender)


func _set_grenades(peer: int) -> void:
	if peer == 1:
		_ev_grenades(int(_grenades[peer]))
	else:
		_ev_grenades.rpc_id(peer, int(_grenades[peer]))


@rpc("authority", "call_remote", "reliable")
func _ev_grenades(count: int) -> void:
	my_grenades = count
	grenades_changed.emit()


func _add_projectile(kind: StringName, pos: Vector3, vel: Vector3, damage: float, owner_peer: int) -> void:
	var p := Projectile.new()
	p.id = _next_projectile_id
	_next_projectile_id += 1
	p.kind = kind
	p.pos = pos
	p.vel = vel
	p.damage = damage
	p.owner_peer = owner_peer
	_projectiles.append(p)
	for peer in World.synced_peers():
		_ev_projectile.rpc_id(peer, p.id, String(kind), pos, vel)
	projectile_spawned.emit(p.id, kind, pos, vel)


@rpc("authority", "call_remote", "reliable")
func _ev_projectile(id: int, kind: String, pos: Vector3, vel: Vector3) -> void:
	projectile_spawned.emit(id, StringName(kind), pos, vel)


@rpc("authority", "call_remote", "reliable")
func _ev_projectile_end(id: int, pos: Vector3, exploded: bool) -> void:
	projectile_ended.emit(id, pos, exploded)


func _end_projectile(p: Projectile, pos: Vector3, exploded: bool) -> void:
	_projectiles.erase(p)
	for peer in World.synced_peers():
		_ev_projectile_end.rpc_id(peer, p.id, pos, exploded)
	projectile_ended.emit(p.id, pos, exploded)


func _update_projectiles(delta: float) -> void:
	var space := _scene.get_world_3d().direct_space_state
	for p: Projectile in _projectiles.duplicate():
		p.age += delta
		if p.kind == &"grenade":
			p.vel.y -= GRENADE_GRAVITY * delta
		var next := p.pos + p.vel * delta
		var shot := p.kind != &"grenade"
		if shot:
			# 플레이어에게 맞았나 (가슴 높이 기준).
			var hit_peer := -1
			for peer: int in vitals:
				if vitals[peer].state != PState.ALIVE or not World.positions.has(peer):
					continue
				var chest := World.positions[peer] + Vector3(0, 0.9, 0)
				if Geometry3D.get_closest_point_to_segment(chest, p.pos, next).distance_to(chest) <= SPIT_HIT_RADIUS:
					hit_peer = peer
					break
			if hit_peer >= 0:
				damage_player(hit_peer, p.damage)
				_end_projectile(p, next, false)
				continue
		var q := PhysicsRayQueryParameters3D.create(p.pos, next, 1 if shot else 3)
		if _local_body.is_valid():
			q.exclude = [_local_body]
		var hit := space.intersect_ray(q)
		if shot:
			if not hit.is_empty() or p.age > SPIT_LIFETIME:
				_end_projectile(p, hit.get("position", next), false)
				continue
		elif not hit.is_empty() or p.age > GRENADE_FUSE:
			_explode(p, hit.get("position", next))
			continue
		p.pos = next


func _explode(p: Projectile, pos: Vector3) -> void:
	_end_projectile(p, pos, true)
	for id: int in enemies.keys():
		var e: Enemy = enemies.get(id)
		if e == null:
			continue
		var dmg := CombatRules.grenade_damage(e.global_position.distance_to(pos))
		if dmg > 0.0:
			_damage_enemy(e, dmg, p.owner_peer)
