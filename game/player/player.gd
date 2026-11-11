class_name PlayerController
extends CharacterBody3D
## 1인칭 플레이어: 이동(걷기·달리기·점프·앉기·슬라이딩), 시점, 사격.
## 이동은 본인 클라이언트 권한이므로(Blueprint D-004) 멀티에서도 이 코드를 그대로 쓴다.

signal weapon_switched(gun: Gun)
signal hit_confirmed(damage: float, head: bool, killed: bool)
signal shot_fired

const STAND_HEIGHT := 1.8
const CROUCH_HEIGHT := 1.1
const RADIUS := 0.35
const EYE_OFFSET := 0.14
const RAY_LENGTH := 300.0

## 조정 패널에 노출할 값: [속성, 최소, 최대, 단계, 표시 이름]
const TUNABLES: Array[Array] = [
	["sens_mult", 0.1, 5.0, 0.05, "마우스 감도"],
	["base_fov", 60, 120, 1, "시야각"],
	["walk_speed", 2, 10, 0.1, "걷기 속도"],
	["sprint_speed", 3, 15, 0.1, "달리기 속도"],
	["crouch_speed", 1, 6, 0.1, "앉아 걷기 속도"],
	["ground_accel", 10, 150, 1, "지상 가속"],
	["air_accel", 0, 60, 1, "공중 가속"],
	["jump_velocity", 3, 12, 0.1, "점프 초속"],
	["gravity", 8, 40, 0.5, "중력"],
	["slide_speed", 6, 18, 0.1, "슬라이딩 초속"],
	["slide_friction", 1, 20, 0.5, "슬라이딩 감속"],
]

var sens_mult: float = 1.0
var base_fov: float = 90.0
var walk_speed: float = 5.0
var sprint_speed: float = 7.5
var crouch_speed: float = 2.5
var ground_accel: float = 70.0
var air_accel: float = 14.0
var jump_velocity: float = 7.0
var gravity: float = 20.0
var slide_speed: float = 10.0
var slide_friction: float = 7.0

var input_enabled: bool = true
var force_active: bool = false    ## 자동 점검용: 마우스가 잡혀 있지 않아도 입력을 받는다
var yaw: float = 0.0
var pitch: float = 0.0
var guns: Array[Gun] = []
var gun: Gun
var ads_amount: float = 0.0
var sliding: bool = false
var crouching: bool = false

# 통계 (사격장 표시용)
var stat_shots: int = 0
var stat_hits: int = 0
var stat_heads: int = 0
var stat_kills: int = 0
var stat_damage: float = 0.0

var camera: Camera3D
var viewmodel: Viewmodel
var sfx: Sfx
var fx: Fx

var _shape: CapsuleShape3D
var _collider: CollisionShape3D
var _height: float = STAND_HEIGHT
var _coyote: float = 0.0
var _jump_buffer: float = 0.0
var _fire_buffer: float = 0.0
var _slide_time: float = 0.0
var _slide_cooldown: float = 0.0
var _slide_dir: Vector3 = Vector3.ZERO
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _land_dip: float = 0.0
var _recoil_target: Vector2 = Vector2.ZERO
var _recoil: Vector2 = Vector2.ZERO
var _shake: float = 0.0
var _fov_punch: float = 0.0
var _fov_smooth: float = 90.0
var _roll: float = 0.0
var _switch_lock: float = 0.0
var _empty_clicked: bool = false


func _ready() -> void:
	_shape = CapsuleShape3D.new()
	_shape.radius = RADIUS
	_shape.height = STAND_HEIGHT
	_collider = CollisionShape3D.new()
	_collider.shape = _shape
	_collider.position.y = STAND_HEIGHT * 0.5
	add_child(_collider)
	floor_snap_length = 0.25
	floor_max_angle = deg_to_rad(46.0)

	# 카메라는 물리 보간을 끄고 매 프레임 직접 놓는다(시점 회전에 지연이 없어야 한다).
	camera = Camera3D.new()
	camera.top_level = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.near = 0.03
	camera.fov = base_fov
	add_child(camera)
	camera.make_current()
	viewmodel = Viewmodel.new()
	camera.add_child(viewmodel)

	for def in WeaponDef.load_all("res://data/weapons.json"):
		var g := Gun.new(def)
		g.reload_started.connect(func() -> void: sfx.play(&"reload", 0.05))
		g.reload_step.connect(func() -> void: sfx.play(&"shell", 0.08))
		g.reload_finished.connect(func() -> void: sfx.play(&"reload", 0.05))
		guns.append(g)
	_equip(0)


func _unhandled_input(event: InputEvent) -> void:
	if not is_active():
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		var zoom := tan(deg_to_rad(camera.fov * 0.5)) / tan(deg_to_rad(base_fov * 0.5))
		var k := deg_to_rad(0.08) * sens_mult * zoom
		yaw -= motion.relative.x * k
		pitch = clampf(pitch - motion.relative.y * k, deg_to_rad(-89.0), deg_to_rad(89.0))
		viewmodel.add_sway(motion.relative)
	elif event.is_action_pressed(&"fire"):
		_fire_buffer = 0.12
	elif event.is_action_pressed(&"jump"):
		_jump_buffer = 0.12
	elif event.is_action_pressed(&"reload"):
		gun.start_reload()
	elif event.is_action_pressed(&"weapon_1"):
		_equip(0)
	elif event.is_action_pressed(&"weapon_2"):
		_equip(1)
	elif event.is_action_pressed(&"weapon_3"):
		_equip(2)
	elif event.is_action_pressed(&"weapon_next"):
		_equip((guns.find(gun) + 1) % guns.size())
	elif event.is_action_pressed(&"weapon_prev"):
		_equip((guns.find(gun) + guns.size() - 1) % guns.size())


func is_active() -> bool:
	return input_enabled and (force_active or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)


func _equip(index: int) -> void:
	if index < 0 or index >= guns.size() or guns[index] == gun:
		return
	if gun != null:
		gun.reload_left = 0.0
	gun = guns[index]
	_switch_lock = 0.25
	_fire_buffer = 0.0
	if viewmodel != null:
		viewmodel.show_weapon(gun.def.id)
	weapon_switched.emit(gun)


func equip_by_id(id: StringName) -> void:
	for i in guns.size():
		if guns[i].def.id == id:
			_equip(i)


func teleport(pos: Vector3, facing_yaw: float) -> void:
	global_position = pos
	velocity = Vector3.ZERO
	yaw = facing_yaw
	pitch = 0.0
	reset_physics_interpolation()


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func current_spread() -> float:
	return gun.spread(ads_amount > 0.5, horizontal_speed() / sprint_speed, not is_on_floor())


# ---------------------------------------------------------------------------
# 이동 (물리 틱)
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var active := is_active()
	var input := Input.get_vector(&"move_left", &"move_right", &"move_forward", &"move_back") if active else Vector2.ZERO
	var wish := (Basis(Vector3.UP, yaw) * Vector3(input.x, 0, input.y)).normalized()
	var on_floor := is_on_floor()
	var want_crouch := active and Input.is_action_pressed(&"crouch")
	var want_sprint := active and Input.is_action_pressed(&"sprint") and input.y < 0.0 and not want_crouch \
			and ads_amount < 0.3 and not (gun.def.auto and Input.is_action_pressed(&"fire"))

	_coyote = 0.1 if on_floor else maxf(_coyote - delta, 0.0)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_slide_cooldown = maxf(_slide_cooldown - delta, 0.0)

	# 슬라이딩 시작: 달리다가 앉기.
	if not sliding and on_floor and want_crouch and not crouching and _slide_cooldown <= 0.0 \
			and horizontal_speed() > walk_speed + 0.5:
		sliding = true
		_slide_time = 0.0
		_slide_dir = Vector3(velocity.x, 0, velocity.z).normalized()
		var boost := maxf(horizontal_speed(), slide_speed)
		velocity.x = _slide_dir.x * boost
		velocity.z = _slide_dir.z * boost
		sfx.play(&"slide", 0.05)

	if sliding:
		_slide_time += delta
		var speed := maxf(horizontal_speed() - slide_friction * delta, 0.0)
		# 슬라이딩 중에는 방향을 조금만 틀 수 있다.
		if wish != Vector3.ZERO:
			_slide_dir = _slide_dir.slerp(wish, minf(1.5 * delta, 1.0)).normalized()
		velocity.x = _slide_dir.x * speed
		velocity.z = _slide_dir.z * speed
		if speed < crouch_speed + 0.5 or not want_crouch or _slide_time > 1.6 or not on_floor:
			sliding = false
			_slide_cooldown = 0.35
	else:
		var max_speed := crouch_speed if crouching else (sprint_speed if want_sprint else walk_speed)
		max_speed *= lerpf(1.0, 0.7, ads_amount)
		var target := wish * max_speed
		var horiz := Vector3(velocity.x, 0, velocity.z)
		if on_floor:
			horiz = horiz.move_toward(target, ground_accel * delta)
		elif wish != Vector3.ZERO:
			# 공중에서는 이미 낸 속도를 깎지 않고 방향만 조금 튼다.
			var limit := maxf(horiz.length(), max_speed)
			horiz = (horiz + wish * air_accel * delta).limit_length(limit)
		velocity.x = horiz.x
		velocity.z = horiz.z

	crouching = (want_crouch or sliding or (crouching and not _can_stand())) and (on_floor or crouching)

	if _jump_buffer > 0.0 and _coyote > 0.0 and (not crouching or sliding or _can_stand()):
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0
		if sliding:
			sliding = false
			_slide_cooldown = 0.35
		crouching = false
		sfx.play(&"jump", 0.05)
	elif not on_floor:
		velocity.y -= gravity * delta

	var target_height := CROUCH_HEIGHT if crouching else STAND_HEIGHT
	_height = move_toward(_height, target_height, 6.0 * delta)
	_shape.height = _height
	_collider.position.y = _height * 0.5

	_fall_speed = -velocity.y if not on_floor else _fall_speed
	move_and_slide()
	if is_on_floor() and not _was_on_floor:
		if _fall_speed > 4.0:
			_land_dip = clampf(_fall_speed * 0.012, 0.03, 0.18)
			sfx.play(&"land", 0.08)
		_fall_speed = 0.0
	_was_on_floor = is_on_floor()


func _can_stand() -> bool:
	var q := PhysicsRayQueryParameters3D.create(
		global_position + Vector3(0, _height - 0.05, 0),
		global_position + Vector3(0, STAND_HEIGHT + 0.05, 0))
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ---------------------------------------------------------------------------
# 시점과 사격 (렌더 프레임)
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var active := is_active()
	for g in guns:
		g.update(delta)
	_switch_lock = maxf(_switch_lock - delta, 0.0)
	_fire_buffer = maxf(_fire_buffer - delta, 0.0)

	var want_ads := active and Input.is_action_pressed(&"aim") and not gun.is_reloading() and _switch_lock <= 0.0
	ads_amount = move_toward(ads_amount, 1.0 if want_ads else 0.0, delta / maxf(gun.def.ads_time, 0.01))

	if active and _switch_lock <= 0.0:
		var want_fire := Input.is_action_pressed(&"fire") if gun.def.auto else _fire_buffer > 0.0
		if want_fire:
			var guard := 0
			while gun.can_fire() and guard < 8:
				_shoot()
				guard += 1
				if not gun.def.auto:
					_fire_buffer = 0.0
					break
			if gun.mag <= 0 and not gun.is_reloading():
				if not _empty_clicked:
					sfx.play(&"empty")
					_empty_clicked = true
				gun.start_reload()
		else:
			_empty_clicked = false

	# 반동: 목표값으로 빠르게 따라가고, 사격을 멈추면 되돌아온다.
	_recoil = _recoil.lerp(_recoil_target, 1.0 - exp(-gun.def.recoil_snap * delta))
	if gun.since_shot > gun.shot_interval() + 0.06:
		_recoil_target = _recoil_target.lerp(Vector2.ZERO, 1.0 - exp(-gun.def.recoil_recover * delta))
	_shake = move_toward(_shake, 0.0, delta * 5.0)
	_fov_punch = move_toward(_fov_punch, 0.0, delta * 12.0)
	_land_dip = move_toward(_land_dip, 0.0, delta * 0.7)

	var strafe := Vector3(velocity.x, 0, velocity.z).dot(Basis(Vector3.UP, yaw).x) / sprint_speed
	var roll_target := -strafe * 0.02 - (0.07 if sliding else 0.0)
	_roll = lerpf(_roll, roll_target, 1.0 - exp(-10.0 * delta))

	var shake_offset := Vector2(randf_range(-1, 1), randf_range(-1, 1)) * deg_to_rad(_shake * 0.6)
	var sprinting := horizontal_speed() > walk_speed + 0.5 and not sliding
	var fov_target := lerpf(base_fov + (5.0 if sprinting else 0.0) + (7.0 if sliding else 0.0), gun.def.ads_fov, ads_amount)
	_fov_smooth = lerpf(_fov_smooth, fov_target, 1.0 - exp(-14.0 * delta))
	camera.fov = _fov_smooth + _fov_punch
	camera.global_position = get_global_transform_interpolated().origin + Vector3(0, _height - EYE_OFFSET - _land_dip, 0)
	camera.rotation = Vector3(
		pitch + deg_to_rad(_recoil.y) + shake_offset.y,
		yaw - deg_to_rad(_recoil.x) + shake_offset.x,
		_roll)

	viewmodel.ads_amount = ads_amount
	viewmodel.move_amount = clampf(horizontal_speed() / sprint_speed, 0.0, 1.0) if not sliding else 0.0
	viewmodel.on_floor = is_on_floor()
	viewmodel.reload_amount = 1.0 if gun.is_reloading() else 0.0


func _shoot() -> void:
	var ads := ads_amount > 0.5
	var spread := deg_to_rad(current_spread())
	var kick := gun.fire(ads)
	_recoil_target += kick
	_shake = minf(_shake + gun.def.shake, 2.0)
	_fov_punch = gun.def.shake * 1.2
	viewmodel.kick(gun.def, ads)
	sfx.play(StringName("shot_" + String(gun.def.id)), 0.04)
	stat_shots += 1
	shot_fired.emit()

	var origin := camera.global_position
	var aim := camera.global_basis
	var space := get_world_3d().direct_space_state
	var per_target: Dictionary[Object, Array] = {}  # 대상 → [피해 합, 머리 여부, 처치 여부, 위치]
	for i in gun.def.pellets:
		# 원뿔 안에서 고르게 뽑는다.
		var r := tan(spread) * sqrt(randf())
		var a := randf() * TAU
		var dir := (aim * Vector3(cos(a) * r, sin(a) * r, -1.0)).normalized()
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LENGTH)
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		var end := origin + dir * 120.0
		if not hit.is_empty():
			end = hit["position"]
			var collider: Object = hit["collider"]
			var is_target := collider.has_method(&"take_hit")
			fx.impact(end, hit["normal"], is_target)
			if is_target:
				var body := collider as CollisionObject3D
				var owner_node: Object = body.shape_owner_get_owner(body.shape_find_owner(hit["shape"]))
				var head := owner_node is Node and (owner_node as Node).name == &"Head"
				var dmg := gun.def.damage * gun.falloff(origin.distance_to(end)) * (gun.def.head_mult if head else 1.0)
				var killed: bool = collider.call(&"take_hit", dmg, head, end)
				var agg: Array = per_target.get(collider, [0.0, false, false, end])
				agg[0] += dmg
				agg[1] = agg[1] or head
				agg[2] = agg[2] or killed
				per_target[collider] = agg
		fx.tracer(viewmodel.muzzle_position(), end)

	if per_target.is_empty():
		return
	var total := 0.0
	var any_head := false
	var any_kill := false
	for target: Object in per_target:
		var agg: Array = per_target[target]
		fx.damage_number(agg[3], agg[0], agg[1], agg[2])
		total += agg[0]
		any_head = any_head or agg[1]
		any_kill = any_kill or agg[2]
		if agg[2]:
			stat_kills += 1
	stat_hits += 1
	stat_damage += total
	if any_head:
		stat_heads += 1
	sfx.play(&"kill" if any_kill else (&"head" if any_head else &"hit"), 0.03)
	hit_confirmed.emit(total, any_head, any_kill)


func reset_stats() -> void:
	stat_shots = 0
	stat_hits = 0
	stat_heads = 0
	stat_kills = 0
	stat_damage = 0.0
