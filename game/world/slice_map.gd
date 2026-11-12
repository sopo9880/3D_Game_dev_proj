class_name SliceMap
extends NavigationRegion3D
## 버티컬 슬라이스의 맵(회색 상자): 정원 → 굽이진 길 → 메마른 골짜기.
## 규칙에 필요한 좌표(건축 구역, 광맥, 비콘 자리, 출현 지점)는 data/map_slice.json과 data/zones.json에
## 있고, 여기서는 그 좌표에 맞춰 지형을 만든다. 골짜기는 복원 진행도에 따라 색과 식생이 바뀐다.

const GRID_SHADER := preload("res://game/range/grid.gdshader")
const BLIGHT_GROUND := Color(0.3, 0.25, 0.29)
const RESTORED_GROUND := Color(0.33, 0.52, 0.32)
const BLIGHT_ROCK := Color(0.27, 0.23, 0.28)
const RESTORED_ROCK := Color(0.5, 0.5, 0.46)

var valley_bounds: Rect2 = Rect2(-60, -330, 120, 140)
var zone_index: int = -1
var spawn_points: Array[Vector3] = []
var boss_spawn: Vector3 = Vector3.ZERO
var boss_radius: float = 26.0
var entrance: Vector3 = Vector3(0, 0, -190)

var _ground_mats: Array[ShaderMaterial] = []
var _rock_mats: Array[ShaderMaterial] = []
var _flora: Array[Array] = []          ## [노드, 나타나는 진행도]
var _shown_progress: float = -1.0
var _target_progress: float = 0.0
var _env: Environment
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20240
	var valley: Dictionary = World.map_data().get("valley", {})
	var b: Array = valley.get("bounds", [-60, -330, 120, 140])
	valley_bounds = Rect2(b[0], b[1], b[2], b[3])
	var zone_def := Registry.db.zone_by_id(StringName(str(valley.get("zone", ""))))
	zone_index = zone_def.index if zone_def != null else -1
	for p: Array in valley.get("spawn_points", []):
		spawn_points.append(Vector3(p[0], p[1] + 0.2, p[2]))
	var bs: Array = valley.get("boss_spawn", [0, 0, -312])
	boss_spawn = Vector3(bs[0], bs[1], bs[2])
	boss_radius = float(valley.get("boss_radius", 26.0))
	var en: Array = valley.get("entrance", [0, 0, -190])
	entrance = Vector3(en[0], en[1], en[2])

	_build_ground()
	_build_path()
	_build_valley()
	World.zone_progress_changed.connect(func(zone: int, progress: int) -> void:
		if zone == zone_index:
			_target_progress = progress)
	World.reset.connect(_sync_progress)
	_sync_progress()


func set_environment(env: Environment) -> void:
	_env = env


func in_valley(pos: Vector3) -> bool:
	return valley_bounds.has_point(Vector2(pos.x, pos.z))


func config() -> Dictionary:
	return {"spawn_points": spawn_points, "zone": zone_index, "boss_spawn": boss_spawn, "boss_radius": boss_radius}


## 길찾기 메시를 굽는다(호스트만). 골짜기 안쪽만 대상으로 한다.
func bake() -> RID:
	var nav := NavigationMesh.new()
	nav.cell_size = 0.25
	nav.cell_height = 0.25
	nav.agent_radius = 0.75
	nav.agent_height = 1.5
	nav.agent_max_climb = 0.25
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.filter_baking_aabb = AABB(
		Vector3(valley_bounds.position.x, -1.0, valley_bounds.position.y),
		Vector3(valley_bounds.size.x, 9.0, valley_bounds.size.y))
	navigation_mesh = nav
	bake_navigation_mesh(false)
	return get_navigation_map()


# ---------------------------------------------------------------------------
# 지형
# ---------------------------------------------------------------------------

func _build_ground() -> void:
	# 전체 바닥. 윗면이 y = 0 이어야 격자 칸과 맞는다. 정원 남쪽의 훈련장부터 골짜기 북쪽 끝까지.
	_box(Vector3(0, -0.5, -110), Vector3(460, 1, 600), Color(0.34, 0.42, 0.36), null)
	# 골짜기 바닥(색이 바뀌는 부분). 전체 바닥보다 살짝 높다.
	var c := valley_bounds.get_center()
	_box(Vector3(c.x, -0.22, c.y), Vector3(valley_bounds.size.x, 0.5, valley_bounds.size.y), BLIGHT_GROUND, _ground_mats)


## 정원 북쪽 끝(z = -64)에서 골짜기 입구(z = -190)까지: 언덕을 돌아가는 길과, 파쿠르로 넘는 지름길.
func _build_path() -> void:
	var rock := Color(0.44, 0.42, 0.4)
	var dirt := Color(0.46, 0.4, 0.32)
	# 길을 막는 큰 언덕 셋: 걸어서는 왼쪽 → 오른쪽 → 왼쪽으로 돌아간다.
	_box(Vector3(-34, 3, -92), Vector3(92, 6, 26), rock, null)
	_box(Vector3(36, 4, -128), Vector3(96, 8, 26), rock, null)
	_box(Vector3(-36, 3.5, -164), Vector3(96, 7, 24), rock, null)
	# 바깥 울타리 구실을 하는 능선.
	_box(Vector3(-86, 5, -128), Vector3(12, 10, 150), rock, null)
	_box(Vector3(86, 5, -128), Vector3(12, 10, 150), rock, null)
	# 지름길 1: 첫 언덕 앞의 계단식 바위. 올라타기와 매달리기로 6m 언덕을 넘는다.
	_box(Vector3(-4, 1.0, -77), Vector3(5, 2, 4), rock, null)
	_box(Vector3(-10, 2.25, -79.5), Vector3(5, 4.5, 3), rock, null)
	# 지름길 2: 첫 언덕 위에서 둘째 언덕으로 건너가는 발판들(간격 3.5m).
	_box(Vector3(-6, 6.5, -108), Vector3(4, 1, 4), rock, null)
	_box(Vector3(2, 7.3, -112), Vector3(4, 1, 4), rock, null)
	# 지름길 3: 셋째 언덕 앞의 3.5m 바위. 매달려 오르면 7m 언덕 위로 이어진다.
	_box(Vector3(6, 1.75, -150), Vector3(4, 3.5, 3), rock, null)
	# 길가의 낮은 바위와 경사로.
	for spec: Array in [[52, -84, 6, 1.6, 5], [56, -100, 4, 2.4, 4], [-58, -120, 5, 1.8, 6], [-62, -138, 4, 3.0, 4],
			[58, -158, 6, 2.0, 5], [20, -178, 4, 1.4, 4], [-18, -182, 3, 1.2, 3]]:
		_box(Vector3(spec[0], spec[3] * 0.5, spec[1]), Vector3(spec[2], spec[3], spec[4]), rock, null)
	_box(Vector3(48, 1.4, -112), Vector3(7, 0.3, 4), dirt, null, Vector3(0, 0, 22))
	# 이정표.
	_sign(Vector3(0, 0, -66), "메마른 골짜기 ↑")
	_sign(Vector3(60, 0, -110), "← 골짜기")
	_sign(Vector3(-60, 0, -146), "골짜기 →")
	_sign(Vector3(50, 0, -182), "← 골짜기 입구")


func _build_valley() -> void:
	var b := valley_bounds
	var c := b.get_center()
	var wall_h := 12.0
	# 절벽. 남쪽 가운데 14m가 입구.
	_box(Vector3(c.x, wall_h * 0.5, b.position.y), Vector3(b.size.x + 4, wall_h, 4), BLIGHT_ROCK, _rock_mats)
	_box(Vector3(b.position.x, wall_h * 0.5, c.y), Vector3(4, wall_h, b.size.y), BLIGHT_ROCK, _rock_mats)
	_box(Vector3(b.end.x, wall_h * 0.5, c.y), Vector3(4, wall_h, b.size.y), BLIGHT_ROCK, _rock_mats)
	var side := (b.size.x - 14.0) * 0.5
	_box(Vector3(b.position.x + side * 0.5, wall_h * 0.5, b.end.y), Vector3(side, wall_h, 4), BLIGHT_ROCK, _rock_mats)
	_box(Vector3(b.end.x - side * 0.5, wall_h * 0.5, b.end.y), Vector3(side, wall_h, 4), BLIGHT_ROCK, _rock_mats)

	# 엄폐용 바위: 낮은 것(1.2m), 올라탈 수 있는 것(2m), 매달려야 하는 것(3.5m).
	for spec: Array in [
			[-22, -204, 5, 1.2, 1.2], [18, -206, 1.2, 1.2, 5], [-6, -216, 4, 1.2, 1.2], [30, -224, 5, 1.2, 1.2],
			[-36, -232, 1.2, 1.2, 5], [8, -242, 6, 1.2, 1.2], [-20, -250, 4, 1.2, 1.2], [28, -254, 1.2, 1.2, 5],
			[-8, -272, 5, 1.2, 1.2], [20, -268, 4, 1.2, 1.2], [-40, -268, 5, 1.2, 1.2], [42, -238, 4, 1.2, 1.2],
			[-28, -214, 6, 2.0, 6], [36, -270, 6, 2.0, 6], [-44, -286, 7, 3.5, 7], [46, -206, 6, 3.5, 6],
			[2, -228, 3, 2.0, 3], [-14, -262, 3, 3.5, 3]]:
		_box(Vector3(spec[0], spec[3] * 0.5, spec[1]), Vector3(spec[2], spec[3], spec[4]), BLIGHT_ROCK, _rock_mats)
	# 우두머리의 터: 돌진을 유도해 부딪히게 할 기둥 넷.
	for px: float in [-13.0, 13.0]:
		for pz: float in [-300.0, -318.0]:
			_box(Vector3(px, 3.0, pz), Vector3(2.4, 6, 2.4), BLIGHT_ROCK, _rock_mats)
	_sign(Vector3(0, 0, -288), "수호체의 터")

	# 비콘 자리 표시.
	if zone_index >= 0:
		var site := Vector3(Registry.db.zones[zone_index].beacon_site) + Vector3(1.5, 0, 1.5)
		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 2.6
		torus.outer_radius = 3.0
		ring.mesh = torus
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.4, 0.9, 0.8)
		mat.emission_enabled = true
		mat.emission = Color(0.3, 0.8, 0.7)
		ring.material_override = mat
		ring.position = site + Vector3(0, 0.05, 0)
		ring.scale.y = 0.2
		add_child(ring)
		_sign(site + Vector3(0, 0, 3.6), "복원 비콘 자리")

	# 식생: 죽은 나무(처음부터 보임)와, 복원이 진행되며 나타나는 풀·꽃·나무.
	for i in 26:
		var p := _valley_point()
		_dead_tree(p)
	for i in 120:
		var p := _valley_point()
		_flora.append([_plant(p, i), [25, 50, 75, 100][i % 4]])


func _valley_point() -> Vector3:
	var b := valley_bounds
	return Vector3(_rng.randf_range(b.position.x + 5, b.end.x - 5), 0.03, _rng.randf_range(b.position.y + 5, b.end.y - 5))


func _dead_tree(pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.05
	mesh.bottom_radius = 0.22
	mesh.height = _rng.randf_range(2.5, 5.0)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.17, 0.19)
	mi.material_override = mat
	mi.position = pos + Vector3(0, mesh.height * 0.5, 0)
	mi.rotation.z = _rng.randf_range(-0.2, 0.2)
	add_child(mi)


func _plant(pos: Vector3, i: int) -> Node3D:
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	match i % 3:
		0:  # 풀
			var mesh := CylinderMesh.new()
			mesh.top_radius = 0.0
			mesh.bottom_radius = 0.35
			mesh.height = 0.7
			mi.mesh = mesh
			mat.albedo_color = Color(0.3, 0.7, 0.3)
			mi.position = pos + Vector3(0, 0.35, 0)
		1:  # 꽃
			var mesh := SphereMesh.new()
			mesh.radius = 0.22
			mesh.height = 0.44
			mi.mesh = mesh
			mat.albedo_color = Color.from_hsv(_rng.randf(), 0.55, 1.0)
			mat.emission_enabled = true
			mat.emission = mat.albedo_color * 0.3
			mi.position = pos + Vector3(0, 0.45, 0)
		_:  # 나무
			var mesh := SphereMesh.new()
			mesh.radius = 1.5
			mesh.height = 3.4
			mi.mesh = mesh
			mat.albedo_color = Color(0.25, 0.6, 0.3)
			mi.position = pos + Vector3(0, 3.2, 0)
			var trunk := MeshInstance3D.new()
			var tm := CylinderMesh.new()
			tm.top_radius = 0.18
			tm.bottom_radius = 0.28
			tm.height = 2.2
			trunk.mesh = tm
			var tmat := StandardMaterial3D.new()
			tmat.albedo_color = Color(0.4, 0.3, 0.2)
			trunk.material_override = tmat
			trunk.position = Vector3(0, -2.1, 0)
			mi.add_child(trunk)
	mi.material_override = mat
	mi.visible = false
	mi.scale = Vector3.ONE * 0.01
	add_child(mi)
	return mi


# ---------------------------------------------------------------------------
# 복원 연출
# ---------------------------------------------------------------------------

func _sync_progress() -> void:
	if zone_index >= 0 and World.sim != null:
		_target_progress = World.sim.zone_progress(zone_index)
		_shown_progress = -1.0


func _process(delta: float) -> void:
	# 진행도 숫자를 화면의 색과 식생으로 서서히 옮긴다.
	if not is_equal_approx(_shown_progress, _target_progress):
		_shown_progress = _target_progress if _shown_progress < 0.0 else move_toward(_shown_progress, _target_progress, delta * 12.0)
		var t := clampf(_shown_progress / 100.0, 0.0, 1.0)
		for m in _ground_mats:
			_tint(m, BLIGHT_GROUND.lerp(RESTORED_GROUND, t))
		for m in _rock_mats:
			_tint(m, BLIGHT_ROCK.lerp(RESTORED_ROCK, t))
		for f: Array in _flora:
			var node: Node3D = f[0]
			if not node.visible and _shown_progress >= float(f[1]):
				node.visible = true
				node.create_tween().tween_property(node, "scale", Vector3.ONE, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
			elif node.visible and _shown_progress < float(f[1]):
				node.visible = false
				node.scale = Vector3.ONE * 0.01


## 플레이어가 골짜기 안에 있을 때, 복원이 덜 된 만큼 탁한 안개가 낀다.
func update_atmosphere(player_pos: Vector3, delta: float) -> void:
	if _env == null:
		return
	var blight := 1.0 - clampf(_shown_progress / 100.0, 0.0, 1.0)
	var inside := 1.0 if in_valley(player_pos) else 0.0
	var target := 0.022 * blight * inside
	_env.fog_enabled = true
	_env.fog_density = lerpf(_env.fog_density, target, 1.0 - exp(-1.5 * delta))
	_env.fog_light_color = Color(0.42, 0.34, 0.44).lerp(Color(0.7, 0.8, 0.85), 1.0 - blight)


func _tint(m: ShaderMaterial, color: Color) -> void:
	m.set_shader_parameter(&"base_color", color)
	m.set_shader_parameter(&"line_color", color.darkened(0.3))


func _sign(pos: Vector3, text: String) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos + Vector3(0, 1.6, 0)
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.pixel_size = 0.008
	l.font_size = 48
	l.outline_size = 12
	add_child(l)


func _box(pos: Vector3, size: Vector3, color: Color, tint_list: Variant, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = GRID_SHADER
	_tint(mat, color)
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	if tint_list != null:
		(tint_list as Array[ShaderMaterial]).append(mat)
	return body
