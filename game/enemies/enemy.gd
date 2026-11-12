class_name Enemy
extends CharacterBody3D
## 적 하나. 호스트에서는 AI가 움직이고, 클라이언트에서는 받은 위치를 따라가는 꼭두각시다.
## 충돌 모양 이름("Body", "Head")은 플레이어의 명중 판정이 부위를 구분하는 데 쓴다.

const GRAVITY := 20.0
const LAYER_ENEMY := 2

var net_id: int = 0
var def: EnemyDef
var hp: float = 1.0
var max_hp: float = 1.0
var puppet: bool = false
var attacking: bool = false          ## 공격 준비 동작 중(표시용, 동기화됨)
var stunned: bool = false            ## 우두머리: 벽에 부딪혀 약점이 드러났다(받는 피해 2배, 동기화됨)
var summons_done: int = 0            ## 우두머리: 이미 부른 소환 횟수

# 꼭두각시용 목표값
var target_pos: Vector3 = Vector3.ZERO
var target_yaw: float = 0.0

var _path: PackedVector3Array = []
var _path_index: int = 0
var _repath: float = 0.0
var _attack_cd: float = 0.0
var _windup: float = -1.0
var _windup_peer: int = -1
var _strafe_dir: float = 1.0
var _strafe_time: float = 0.0
var _evade: float = 0.0
var _phase: float = 0.0
var _flash: float = 0.0
var _stun: float = 0.0
# 우두머리 상태 기계
enum Boss { CHASE, TELEGRAPH, DASH, STUNNED, CAST }
var _boss_state: int = Boss.CHASE
var _boss_t: float = 2.0
var _dash_dir: Vector3 = Vector3.FORWARD
var _dash_hit: Dictionary[int, bool] = {}
var _next_is_charge: bool = true
var _instant: bool = false
var _mat: StandardMaterial3D
var _label: Label3D
var _visual: Node3D


func setup(id: int, enemy_def: EnemyDef, health: float, is_puppet: bool) -> void:
	net_id = id
	def = enemy_def
	hp = health
	max_hp = health
	puppet = is_puppet


func _ready() -> void:
	collision_layer = LAYER_ENEMY
	collision_mask = 1
	_phase = randf() * TAU
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.55, 0.2, 0.5) if def.kind == &"melee" else Color(0.3, 0.55, 0.3)
	if def.kind == &"boss":
		_mat.albedo_color = Color(0.3, 0.12, 0.18)
	_mat.emission_enabled = true
	_mat.emission = Color.BLACK
	_mat.roughness = 0.7
	_visual = Node3D.new()
	add_child(_visual)

	var body_shape := CapsuleShape3D.new()
	body_shape.radius = def.radius
	body_shape.height = maxf(def.height, def.radius * 2.0)
	var body := CollisionShape3D.new()
	body.name = &"Body"
	body.shape = body_shape
	body.position.y = body_shape.height * 0.5
	add_child(body)
	var body_mesh := CapsuleMesh.new()
	body_mesh.radius = def.radius
	body_mesh.height = body_shape.height
	_mesh(body_mesh, body.position)

	var head_shape := SphereShape3D.new()
	head_shape.radius = def.head_radius
	var head := CollisionShape3D.new()
	head.name = &"Head"
	head.shape = head_shape
	# 돌진형은 머리가 앞으로 나와 있고, 원거리형은 위에 있다.
	head.position = Vector3(0, def.height + def.head_radius * 0.6, 0)
	if def.kind == &"melee":
		head.position = Vector3(0, def.height * 0.75, -def.radius * 0.9)
	elif def.kind == &"boss":
		head.position = Vector3(0, def.height * 0.72, -def.radius * 0.95)
	add_child(head)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = def.head_radius
	head_mesh.height = def.head_radius * 2.0
	_mesh(head_mesh, head.position).material_override = _head_material()

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position.y = def.height + 0.75
	_label.pixel_size = 0.004
	_label.font_size = 32
	_label.outline_size = 8
	_label.no_depth_test = true
	add_child(_label)
	target_pos = position
	if puppet:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func eye_position() -> Vector3:
	return global_position + Vector3(0, def.height * 0.8, 0)


## 플레이어의 사격이 맞았을 때 불린다. 피해 계산과 처치 판정은 호스트가 하므로 보고만 한다.
func take_hit(_damage: float, head: bool, _pos: Vector3) -> bool:
	_flash = 1.0
	Combat.queue_hit(net_id, head)
	return false


## 맞았다는 표시만 한다(판정은 호스트가 따로 한다).
func flash() -> void:
	_flash = 1.0


## 호스트: 근접 공격에 맞아 움찔한다. 하던 공격이 끊기고 뒤로 밀린다.
func stagger(away: Vector3) -> void:
	_windup = -1.0
	attacking = false
	_attack_cd = maxf(_attack_cd, 0.7)
	_stun = 0.35
	away.y = 0.0
	velocity = away.normalized() * 4.0 + Vector3(0, 2.0, 0)


## 호스트: 피해를 입었다. 원거리형은 자리를 옮긴다.
func on_damaged() -> void:
	_flash = 1.0
	if def.kind == &"ranged":
		_evade = 0.9
		_strafe_dir = -_strafe_dir


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 7.0, 0.0)
	var glow := Color(1, 1, 1) * _flash + (Color(1.0, 0.3, 0.1) * 0.9 if attacking else Color.BLACK)
	if stunned:
		glow += Color(0.2, 0.7, 1.0) * 0.8
	_mat.emission = glow
	_label.text = ("약점 노출!  " if stunned else "") + str(ceili(maxf(hp, 0.0)))
	_label.modulate.a = 1.0 if hp < max_hp or def.kind == &"boss" else 0.0
	# 공격 준비 중에는 몸을 움츠린다.
	_visual.scale = _visual.scale.lerp(Vector3(1.15, 0.8, 1.15) if attacking else Vector3.ONE, 1.0 - exp(-14.0 * delta))
	if puppet:
		var k := 1.0 - exp(-12.0 * delta)
		position = target_pos if position.distance_to(target_pos) > 6.0 else position.lerp(target_pos, k)
		rotation.y = lerp_angle(rotation.y, target_yaw, k)


func _physics_process(delta: float) -> void:
	if puppet:
		return
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_repath -= delta
	_phase += delta * 5.0
	var horizontal := Vector3.ZERO
	var target := Combat.nearest_alive_player(global_position, def.aggro_range)
	var peer: int = target[0]
	_stun = maxf(_stun - delta, 0.0)
	if _stun > 0.0:
		# 움찔하는 동안은 밀려나기만 한다.
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return
	if peer >= 0:
		var goal: Vector3 = target[1]
		var to := goal - global_position
		to.y = 0.0
		var dist := to.length()
		var dir := to / maxf(dist, 0.001)
		match def.kind:
			&"melee": horizontal = _think_melee(peer, goal, dist, dir, delta)
			&"boss": horizontal = _think_boss(peer, goal, dist, dir, delta)
			_: horizontal = _think_ranged(peer, goal, dist, dir, delta)
		if _boss_state == Boss.DASH:
			rotation.y = atan2(-_dash_dir.x, -_dash_dir.z)
		elif attacking or horizontal.length() < 0.1:
			rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), minf(10.0 * delta, 1.0))
		else:
			rotation.y = lerp_angle(rotation.y, atan2(-horizontal.x, -horizontal.z), minf(10.0 * delta, 1.0))
	else:
		attacking = false
		stunned = false
		_windup = -1.0
		_boss_state = Boss.CHASE
	var h := Vector3(velocity.x, 0, velocity.z).move_toward(horizontal, 30.0 * delta)
	if _instant:
		h = horizontal
		_instant = false
	velocity.x = h.x
	velocity.z = h.z
	velocity.y = velocity.y - GRAVITY * delta if not is_on_floor() else -0.5
	move_and_slide()


func _think_melee(peer: int, goal: Vector3, dist: float, dir: Vector3, delta: float) -> Vector3:
	if _windup >= 0.0:
		_windup -= delta
		if _windup <= 0.0:
			_windup = -1.0
			attacking = false
			_attack_cd = def.attack_interval
			# 준비 동작 동안 빠져나갔으면 맞지 않는다.
			if dist <= def.attack_range + 0.6:
				Combat.damage_player(_windup_peer, def.attack_damage)
		return Vector3.ZERO
	if dist <= def.attack_range:
		if _attack_cd <= 0.0:
			_windup = def.attack_windup
			_windup_peer = peer
			attacking = true
		return Vector3.ZERO
	var move := _path_direction(goal, dir)
	# 멀리서는 지그재그로 다가온다.
	if dist > 5.0:
		move = (move + move.cross(Vector3.UP) * sin(_phase) * 0.6).normalized()
	return move * def.speed


func _think_ranged(peer: int, goal: Vector3, dist: float, dir: Vector3, delta: float) -> Vector3:
	_strafe_time -= delta
	if _strafe_time <= 0.0:
		_strafe_time = randf_range(1.5, 3.0)
		_strafe_dir = -_strafe_dir
	_evade = maxf(_evade - delta, 0.0)
	var side := dir.cross(Vector3.UP) * _strafe_dir

	if _windup >= 0.0:
		_windup -= delta
		if _windup <= 0.0:
			_windup = -1.0
			attacking = false
			_attack_cd = def.attack_interval
			var from := eye_position()
			var aim := (goal + Vector3(0, 0.9, 0) - from).normalized()
			Combat.spawn_spit(from + aim * 0.5, aim * def.projectile_speed, def.attack_damage)
		return Vector3.ZERO
	if _evade > 0.0:
		return side * def.speed * 1.4
	if _attack_cd <= 0.0 and dist <= def.attack_range and Combat.has_line_of_sight(eye_position(), goal + Vector3(0, 0.9, 0)):
		_windup = def.attack_windup
		_windup_peer = peer
		attacking = true
		return Vector3.ZERO
	if dist < def.keep_min:
		return (-dir + side * 0.4).normalized() * def.speed
	if dist > def.keep_max:
		return _path_direction(goal, dir) * def.speed
	return side * def.speed * 0.5


## 우두머리: 돌진(예고 → 직선 돌진, 벽에 부딪히면 약점 노출)과 포격(바닥 표시 → 폭발)을 번갈아 한다.
func _think_boss(peer: int, goal: Vector3, dist: float, dir: Vector3, delta: float) -> Vector3:
	_boss_t -= delta
	match _boss_state:
		Boss.TELEGRAPH:
			# 예고 끝 무렵에 방향이 굳는다. 그 뒤에 옆으로 비키면 빗나간다.
			if _boss_t > 0.35:
				_dash_dir = dir
			if _boss_t <= 0.0:
				attacking = false
				_boss_state = Boss.DASH
				_boss_t = def.charge_time
				_dash_hit.clear()
			return Vector3.ZERO
		Boss.DASH:
			for p: int in Combat.vitals:
				if _dash_hit.has(p) or not Combat.is_alive(p) or not World.positions.has(p):
					continue
				var to := World.positions[p] - global_position
				if Vector2(to.x, to.z).length() <= def.radius + 1.0 and absf(to.y) < def.height:
					_dash_hit[p] = true
					Combat.damage_player(p, def.attack_damage)
			var speed_now := Vector2(get_real_velocity().x, get_real_velocity().z).length()
			if is_on_wall() and _boss_t < def.charge_time - 0.15 and speed_now < def.charge_speed * 0.4:
				_boss_state = Boss.STUNNED
				_boss_t = def.stun_time
				stunned = true
				_flash = 1.0
				return Vector3.ZERO
			if _boss_t <= 0.0:
				_boss_state = Boss.CHASE
				_boss_t = def.attack_interval
				return Vector3.ZERO
			_instant = true
			return _dash_dir * def.charge_speed
		Boss.STUNNED:
			if _boss_t <= 0.0:
				stunned = false
				_boss_state = Boss.CHASE
				_boss_t = 0.8
			return Vector3.ZERO
		Boss.CAST:
			if _boss_t <= 0.0:
				attacking = false
				Combat.boss_barrage(self, peer)
				_boss_state = Boss.CHASE
				_boss_t = def.attack_interval
			return Vector3.ZERO
	# CHASE: 적당한 거리까지 다가가며 다음 공격을 고른다.
	if _boss_t <= 0.0:
		attacking = true
		if _next_is_charge:
			_boss_state = Boss.TELEGRAPH
			_boss_t = def.attack_windup
			_dash_dir = dir
		else:
			_boss_state = Boss.CAST
			_boss_t = 0.6
		_next_is_charge = not _next_is_charge
		return Vector3.ZERO
	return _path_direction(goal, dir) * def.speed if dist > 10.0 else Vector3.ZERO


## 길찾기 결과를 따라갈 방향. 길이 없으면 목표 쪽으로 곧장 간다.
func _path_direction(goal: Vector3, fallback: Vector3) -> Vector3:
	if _repath <= 0.0:
		_repath = 0.4
		_path = Combat.find_path(global_position, goal)
		_path_index = 1 if _path.size() > 1 else 0
	while _path_index < _path.size():
		var to := _path[_path_index] - global_position
		to.y = 0.0
		if to.length() > 0.6:
			return to.normalized()
		_path_index += 1
	return fallback


func _mesh(mesh: Mesh, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _mat
	_visual.add_child(mi)
	return mi


func _head_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.85, 0.3)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.7, 0.2) * 0.4
	return m
