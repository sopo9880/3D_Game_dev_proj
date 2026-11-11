class_name Viewmodel
extends Node3D
## 1인칭 총 모형(임시 상자 모델). 반동, 흔들림, 조준 위치, 총구 화염을 담당한다.

const HIP_POS := Vector3(0.24, -0.23, -0.5)
const ADS_POS := Vector3(0.0, -0.105, -0.3)

var ads_amount: float = 0.0       ## 0 = 허리, 1 = 조준
var move_amount: float = 0.0      ## 0..1 이동 속도 비율
var on_floor: bool = true
var reload_amount: float = 0.0    ## 재장전 중 1

var _gun: Node3D
var _muzzle: Node3D
var _flash: MeshInstance3D
var _flash_light: OmniLight3D
var _kick_pos: float = 0.0
var _kick_rot: float = 0.0
var _kick_pos_vel: float = 0.0
var _kick_rot_vel: float = 0.0
var _sway: Vector2 = Vector2.ZERO
var _bob_time: float = 0.0
var _flash_time: float = 0.0
var _reload_blend: float = 0.0
var _switch_drop: float = 0.0


func _ready() -> void:
	_gun = Node3D.new()
	add_child(_gun)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = Color(1.0, 0.8, 0.5)
	_flash_light.omni_range = 6.0
	_flash_light.light_energy = 0.0
	_flash_light.shadow_enabled = false
	add_child(_flash_light)
	_flash_light.position = Vector3(0.2, -0.1, -1.0)
	show_weapon(&"rifle")


func muzzle_position() -> Vector3:
	return _muzzle.global_position


func show_weapon(id: StringName) -> void:
	for c in _gun.get_children():
		c.queue_free()
	var dark := _mat(Color(0.16, 0.17, 0.19))
	var accent := _mat(Color(0.32, 0.52, 0.42))
	var barrel_len := 0.3
	match id:
		&"pistol":
			_box(Vector3(0.035, 0.05, 0.2), Vector3(0, 0, -0.02), dark)
			_box(Vector3(0.032, 0.11, 0.045), Vector3(0, -0.07, 0.05), accent).rotation_degrees.x = -12
			barrel_len = 0.12
		&"shotgun":
			_box(Vector3(0.05, 0.065, 0.38), Vector3(0, 0, 0.0), dark)
			_box(Vector3(0.036, 0.036, 0.42), Vector3(0, 0.012, -0.36), dark)
			_box(Vector3(0.05, 0.04, 0.2), Vector3(0, -0.035, -0.28), accent)
			_box(Vector3(0.042, 0.075, 0.2), Vector3(0, -0.03, 0.26), accent).rotation_degrees.x = -8
			barrel_len = 0.57
		_:
			_box(Vector3(0.045, 0.07, 0.42), Vector3(0, 0, 0.0), dark)
			_box(Vector3(0.026, 0.026, 0.26), Vector3(0, 0.01, -0.32), dark)
			_box(Vector3(0.034, 0.13, 0.055), Vector3(0, -0.095, -0.03), accent).rotation_degrees.x = 10
			_box(Vector3(0.036, 0.09, 0.045), Vector3(0, -0.075, 0.13), dark).rotation_degrees.x = -14
			_box(Vector3(0.04, 0.06, 0.2), Vector3(0, -0.01, 0.3), accent)
			_box(Vector3(0.012, 0.03, 0.012), Vector3(0, 0.05, -0.18), dark)
			_box(Vector3(0.03, 0.022, 0.012), Vector3(0, 0.046, 0.16), dark)
			barrel_len = 0.45
	_muzzle = Node3D.new()
	_muzzle.position = Vector3(0, 0.012, -barrel_len)
	_gun.add_child(_muzzle)
	_flash = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.16, 0.16)
	_flash.mesh = quad
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.albedo_color = Color(1.0, 0.75, 0.35)
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_flash.material_override = fm
	_flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flash.visible = false
	_muzzle.add_child(_flash)
	_switch_drop = 1.0


func kick(def: WeaponDef, ads: bool) -> void:
	var scale_amount := 0.6 if ads else 1.0
	_kick_pos_vel += def.kick_back * 38.0 * scale_amount
	_kick_rot_vel += def.kick_up * 34.0 * scale_amount
	_flash_time = 0.045
	_flash.visible = true
	_flash.scale = Vector3.ONE * randf_range(0.8, 1.5) * (1.6 if def.pellets > 1 else 1.0)
	_flash.rotation.z = randf() * TAU
	_flash_light.light_energy = 2.5


## 총을 잠깐 내린다(올라타기 등 손을 쓰는 동작).
func dip(amount: float) -> void:
	_switch_drop = maxf(_switch_drop, amount)


func add_sway(mouse_delta: Vector2) -> void:
	_sway += mouse_delta * 0.00035


func _process(delta: float) -> void:
	# 프레임이 크게 끊겨도 스프링이 발산하지 않게 한다.
	delta = minf(delta, 1.0 / 30.0)
	# 반동: 감쇠 스프링으로 제자리로 돌아온다.
	_kick_pos_vel += (-_kick_pos * 260.0 - _kick_pos_vel * 24.0) * delta
	_kick_pos += _kick_pos_vel * delta
	_kick_rot_vel += (-_kick_rot * 240.0 - _kick_rot_vel * 22.0) * delta
	_kick_rot += _kick_rot_vel * delta

	_sway = _sway.lerp(Vector2.ZERO, 1.0 - exp(-10.0 * delta))
	_sway = _sway.limit_length(0.04)
	if on_floor and move_amount > 0.05:
		_bob_time += delta * (6.0 + 6.0 * move_amount)
	var bob_scale := move_amount * (1.0 - ads_amount * 0.85) * (0.012 if on_floor else 0.0)
	var bob := Vector3(cos(_bob_time) * bob_scale, -absf(sin(_bob_time)) * bob_scale, 0.0)

	_reload_blend = move_toward(_reload_blend, reload_amount, delta * 7.0)
	_switch_drop = move_toward(_switch_drop, 0.0, delta * 6.0)
	var lowered := maxf(_reload_blend * 0.6, _switch_drop)

	var base := HIP_POS.lerp(ADS_POS, ads_amount)
	_gun.position = base + bob + Vector3(-_sway.x, _sway.y - lowered * 0.16, _kick_pos)
	_gun.rotation = Vector3(
		deg_to_rad(_kick_rot) - lowered * 0.7 + _sway.y * 1.5,
		-_sway.x * 2.0,
		-_sway.x * 1.5 + _reload_blend * 0.35)

	if _flash_time > 0.0:
		_flash_time -= delta
		if _flash_time <= 0.0:
			_flash.visible = false
	_flash_light.light_energy = move_toward(_flash_light.light_energy, 0.0, delta * 45.0)


func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.material_override = mat
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gun.add_child(node)
	return node


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.6
	m.metallic = 0.3
	return m
