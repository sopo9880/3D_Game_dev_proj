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
	head.position = Vector3(0, def.height * 0.75, -def.radius * 0.9) if def.kind == &"melee" \
			else Vector3(0, def.height + def.head_radius * 0.6, 0)
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
	_mat.emission = glow
	_label.text = str(ceili(maxf(hp, 0.0)))
	_label.modulate.a = 1.0 if hp < max_hp else 0.0
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
	if peer >= 0:
		var goal: Vector3 = target[1]
		var to := goal - global_position
		to.y = 0.0
		var dist := to.length()
		var dir := to / maxf(dist, 0.001)
		horizontal = _think_melee(peer, goal, dist, dir, delta) if def.kind == &"melee" \
				else _think_ranged(peer, goal, dist, dir, delta)
		if attacking or horizontal.length() < 0.1:
			rotation.y = lerp_angle(rotation.y, atan2(-dir.x, -dir.z), minf(10.0 * delta, 1.0))
		else:
			rotation.y = lerp_angle(rotation.y, atan2(-horizontal.x, -horizontal.z), minf(10.0 * delta, 1.0))
	else:
		attacking = false
		_windup = -1.0
	var h := Vector3(velocity.x, 0, velocity.z).move_toward(horizontal, 30.0 * delta)
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
