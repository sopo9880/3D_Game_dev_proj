class_name RangeTarget
extends AnimatableBody3D
## 사격장 표적. 몸통과 머리 판정이 따로 있다.

signal died(target: RangeTarget)

var max_hp: float = 100.0
var respawn_time: float = 2.0      ## 0 이하면 다시 나타나지 않는다
var invulnerable: bool = false     ## DPS 측정용 허수아비
var move_axis: Vector3 = Vector3.ZERO
var move_range: float = 0.0
var move_speed: float = 0.0

var hp: float = 100.0
var _origin: Vector3
var _phase: float = 0.0
var _body_mat: StandardMaterial3D
var _head_mat: StandardMaterial3D
var _label: Label3D
var _flash: float = 0.0
var _alive: bool = true
var _recent: Array[Vector2] = []   ## (시각, 피해) — DPS 계산용
var _total: float = 0.0
var _shapes: Array[CollisionShape3D] = []


func _ready() -> void:
	sync_to_physics = false
	hp = max_hp
	_origin = position
	var color := Color(0.35, 0.6, 0.9) if invulnerable else Color(0.85, 0.45, 0.25)
	_body_mat = _mat(color)
	_head_mat = _mat(color.lightened(0.25))

	var post := MeshInstance3D.new()
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.04
	post_mesh.bottom_radius = 0.06
	post_mesh.height = 0.45
	post.mesh = post_mesh
	post.position.y = 0.225
	post.material_override = _mat(Color(0.25, 0.25, 0.28))
	add_child(post)

	var body_size := Vector3(0.55, 1.05, 0.28)
	_add_part(&"Body", _box_mesh(body_size), _box_shape(body_size), Vector3(0, 0.975, 0), _body_mat)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.17
	head_mesh.height = 0.34
	var head_shape := SphereShape3D.new()
	head_shape.radius = 0.17
	_add_part(&"Head", head_mesh, head_shape, Vector3(0, 1.69, 0), _head_mat)

	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position.y = 2.1
	_label.pixel_size = 0.004
	_label.font_size = 40
	_label.outline_size = 10
	_label.no_depth_test = true
	add_child(_label)
	_refresh_label()


## 피해를 준다. 이번 피해로 쓰러졌으면 true.
func take_hit(damage: float, _head: bool, _pos: Vector3) -> bool:
	if not _alive:
		return false
	_flash = 1.0
	var now := Time.get_ticks_msec() / 1000.0
	_recent.append(Vector2(now, damage))
	_total += damage
	if invulnerable:
		_refresh_label()
		return false
	hp -= damage
	_refresh_label()
	if hp > 0.0:
		return false
	_set_alive(false)
	died.emit(self)
	if respawn_time > 0.0:
		get_tree().create_timer(respawn_time).timeout.connect(_respawn)
	return true


func reset() -> void:
	_recent.clear()
	_total = 0.0
	_respawn()


func _respawn() -> void:
	hp = max_hp
	_set_alive(true)
	_refresh_label()


func _set_alive(alive: bool) -> void:
	_alive = alive
	visible = alive
	for s in _shapes:
		s.set_deferred(&"disabled", not alive)


func _physics_process(delta: float) -> void:
	if move_speed > 0.0 and move_range > 0.0:
		_phase += delta * move_speed / move_range
		position = _origin + move_axis * sin(_phase) * move_range


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 8.0, 0.0)
		var e := Color(1, 1, 1) * _flash * 1.5
		_body_mat.emission = e
		_head_mat.emission = e
	if invulnerable and not _recent.is_empty():
		var now := Time.get_ticks_msec() / 1000.0
		while not _recent.is_empty() and now - _recent[0].x > 3.0:
			_recent.pop_front()
		_refresh_label()


func _refresh_label() -> void:
	if invulnerable:
		var sum := 0.0
		for r in _recent:
			sum += r.y
		var span := 3.0
		if not _recent.is_empty():
			span = clampf(Time.get_ticks_msec() / 1000.0 - _recent[0].x, 0.5, 3.0)
		_label.text = "DPS %d\n누적 %d" % [roundi(sum / span), roundi(_total)]
	else:
		_label.text = str(ceili(maxf(hp, 0.0)))


func _add_part(part_name: StringName, mesh: Mesh, shape: Shape3D, pos: Vector3, mat: Material) -> void:
	var col := CollisionShape3D.new()
	col.name = part_name
	col.shape = shape
	col.position = pos
	add_child(col)
	_shapes.append(col)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	col.add_child(mi)


func _box_mesh(size: Vector3) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	return m


func _box_shape(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new()
	s.size = size
	return s


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.8
	m.emission_enabled = true
	m.emission = Color.BLACK
	return m
