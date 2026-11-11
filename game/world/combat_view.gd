class_name CombatView
extends Node3D
## 전투 상태(Combat)를 화면과 조작에 연결한다: 체력 표시, 쓰러짐, 부활, 투척, 투사체와 폭발 효과.

const REVIVE_HOLD := 2.0
const THROW_SPEED := 18.0

var player: PlayerController
var hud: Hud
var fx: Fx
var sfx: Sfx
var yard: CombatYard

var _orbs: Dictionary[int, Array] = {}     ## 투사체 ID → [표시 노드, 속도, 종류]
var _revive_hold: float = 0.0
var _resupply_timer: float = 0.0
var _last_hp: float = CombatRules.MAX_HP


func _ready() -> void:
	Combat.respawned.connect(_on_respawned)
	Combat.enemy_died.connect(_on_enemy_died)
	World.items_gained.connect(_on_items_gained)
	Combat.shot_seen.connect(_on_shot_seen)
	Combat.projectile_spawned.connect(_on_projectile)
	Combat.projectile_ended.connect(_on_projectile_end)


func _unhandled_input(event: InputEvent) -> void:
	if player.is_active() and event.is_action_pressed(&"throw") and Combat.my_grenades > 0:
		var forward := -player.camera.global_basis.z
		Combat.request_throw(player.camera.global_position + forward * 0.6, forward * THROW_SPEED + Vector3(0, 4, 0))
		player.viewmodel.dip(0.5)


func _process(delta: float) -> void:
	var me := Combat.my_vitals()
	if me == null:
		return
	if me.hp < _last_hp - 0.5:
		hud.hurt()
		sfx.play(&"land", 0.1)
	_last_hp = me.hp
	player.downed = me.state == Combat.PState.DOWNED
	hud.health = me.hp
	hud.grenades = Combat.my_grenades

	var lines: PackedStringArray = []
	var inv := World.my_inventory()
	for item: int in inv:
		lines.append("%s  %d" % [Registry.db.item_def(item).display_name, int(inv[item])])
	hud.side_text = "\n".join(lines)

	hud.center_text = ""
	if player.downed:
		hud.center_text = "쓰러졌습니다\n%.0f초 뒤 시작 지점에서 다시 일어납니다" % maxf(me.down_left, 0.0)
		_revive_hold = 0.0
	else:
		_update_revive(delta)

	# 보급 상자 옆에 있으면 투척류를 채운다.
	_resupply_timer -= delta
	if _resupply_timer <= 0.0 and Combat.my_grenades < CombatRules.GRENADE_MAX \
			and player.global_position.distance_to(yard.crate_position) < 2.5:
		_resupply_timer = 1.0
		Combat.request_resupply()

	for id: int in _orbs:
		var o: Array = _orbs[id]
		var node: MeshInstance3D = o[0]
		var vel: Vector3 = o[1]
		if o[2] == &"grenade":
			vel.y -= Combat.GRENADE_GRAVITY * delta
			o[1] = vel
		node.global_position += vel * delta


func _update_revive(delta: float) -> void:
	var target := -1
	for peer: int in Combat.vitals:
		if peer == Net.my_id() or Combat.vitals[peer].state != Combat.PState.DOWNED or not World.positions.has(peer):
			continue
		if World.positions[peer].distance_to(player.global_position) <= CombatRules.REVIVE_RANGE:
			target = peer
			break
	if target < 0:
		_revive_hold = 0.0
		return
	if Input.is_action_pressed(&"interact") and player.is_active():
		_revive_hold += delta
		hud.center_text = "일으키는 중… %d%%" % int(_revive_hold / REVIVE_HOLD * 100.0)
		if _revive_hold >= REVIVE_HOLD:
			_revive_hold = 0.0
			Combat.request_revive(target)
	else:
		_revive_hold = 0.0
		hud.center_text = "E를 누르고 있으면 동료를 일으킵니다"


func _on_respawned(pos: Vector3) -> void:
	player.teleport(pos, 0.0)
	_last_hp = CombatRules.MAX_HP


func _on_enemy_died(_id: int, pos: Vector3, killer: int) -> void:
	fx.impact(pos + Vector3(0, 0.8, 0), Vector3.UP, false)
	if killer == Net.my_id():
		hud.on_hit(0.0, false, true)
		sfx.play(&"kill", 0.03)
		player.stat_kills += 1


func _on_items_gained(key: String, gained: Dictionary) -> void:
	if key != World.my_key():
		return
	var parts: PackedStringArray = []
	for id: String in gained:
		var def: ItemDef = Registry.db.items.get(StringName(id))
		parts.append("+%d %s" % [int(gained[id]), def.display_name if def != null else id])
	if not parts.is_empty():
		hud.toast("  ".join(parts))


func _on_shot_seen(peer: int, weapon_id: StringName, from: Vector3, to: Vector3) -> void:
	if peer == Net.my_id():
		return
	fx.tracer(from, to)
	if from.distance_to(player.global_position) < 70.0:
		sfx.play(StringName("shot_" + String(weapon_id)), 0.05)


func _on_projectile(id: int, kind: StringName, pos: Vector3, vel: Vector3) -> void:
	var node := fx.orb(Color(0.6, 1.0, 0.3) if kind == &"spit" else Color(0.95, 0.8, 0.3), 0.14 if kind == &"spit" else 0.11)
	node.global_position = pos
	_orbs[id] = [node, vel, kind]


func _on_projectile_end(id: int, pos: Vector3, exploded: bool) -> void:
	if _orbs.has(id):
		(_orbs[id][0] as Node).queue_free()
		_orbs.erase(id)
	if exploded:
		fx.explosion(pos, CombatRules.GRENADE_RADIUS)
		sfx.play(&"shot_shotgun", 0.1)
	else:
		fx.impact(pos, Vector3.UP, true)
