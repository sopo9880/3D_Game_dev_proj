class_name SliceMap
extends NavigationRegion3D
## 버티컬 슬라이스의 맵(회색 상자): 정원 → 굽이진 길 → 메마른 골짜기, 그리고 정원 동쪽의 녹슨 채석장.
## 규칙에 필요한 좌표(건축 구역, 광맥, 비콘 자리, 출현 지점)는 data/map_slice.json과 data/zones.json에
## 있고, 여기서는 그 좌표에 맞춰 지형을 만든다. 오염 구역은 복원 진행도에 따라 색과 식생이 바뀐다.

const GRID_SHADER := preload("res://game/range/grid.gdshader")
const NAV_GROUP := &"slice_map_geometry"
const ENTRANCE_WIDTH := 14.0
const WALL_HEIGHT := 12.0
## 구역별 색: [오염된 땅, 복원된 땅, 오염된 바위, 복원된 바위, 안개]
const PALETTES: Array[Array] = [
	[Color(0.3, 0.25, 0.29), Color(0.33, 0.52, 0.32), Color(0.27, 0.23, 0.28), Color(0.5, 0.5, 0.46), Color(0.42, 0.34, 0.44)],
	[Color(0.36, 0.27, 0.21), Color(0.45, 0.5, 0.34), Color(0.34, 0.24, 0.19), Color(0.56, 0.52, 0.46), Color(0.5, 0.36, 0.26)],
]


## 오염 구역 하나의 지형과 연출 상태.
class Area:
	var slot: int = 0                  ## 맵 데이터의 zones 순서(전투의 구역 순번과 같다)
	var index: int = -1                ## 구역 인덱스(ContentDB)
	var requires: int = -1             ## 먼저 복원해야 하는 구역 인덱스
	var bounds: Rect2
	var entrance: Vector3
	var spawn_points: Array[Vector3] = []
	var spawn_types: Array[StringName] = []
	var boss: StringName = &""
	var boss_spawn: Vector3 = Vector3.ZERO
	var boss_radius: float = 0.0
	var ground_mats: Array[ShaderMaterial] = []
	var rock_mats: Array[ShaderMaterial] = []
	var flora: Array[Array] = []       ## [노드, 나타나는 진행도]
	var gate: Node3D = null            ## 선행 구역을 복원하기 전까지 입구를 막는 벽
	var shown: float = -1.0
	var target: float = 0.0
	var palette: Array = []


var areas: Array[Area] = []
var zone_index: int = -1               ## 첫 구역(메마른 골짜기)의 인덱스

var _extra_regions: Array[NavigationRegion3D] = []
var _env: Environment
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20240
	add_to_group(NAV_GROUP)
	for row: Dictionary in World.map_data().get("zones", []):
		var a := Area.new()
		a.slot = areas.size()
		var b: Array = row.get("bounds", [-60, -330, 120, 140])
		a.bounds = Rect2(b[0], b[1], b[2], b[3])
		var zone_def := Registry.db.zone_by_id(StringName(str(row.get("zone", ""))))
		if zone_def != null:
			a.index = zone_def.index
			a.requires = zone_def.requires
		for p: Array in row.get("spawn_points", []):
			a.spawn_points.append(Vector3(p[0], p[1] + 0.2, p[2]))
		for t: Variant in row.get("spawn_types", []):
			a.spawn_types.append(StringName(str(t)))
		a.boss = StringName(str(row.get("boss", "")))
		var bs: Array = row.get("boss_spawn", [0, 0, 0])
		a.boss_spawn = Vector3(bs[0], bs[1], bs[2])
		a.boss_radius = float(row.get("boss_radius", 0.0))
		var en: Array = row.get("entrance", [0, 0, 0])
		a.entrance = Vector3(en[0], en[1], en[2])
		a.palette = PALETTES[mini(a.slot, PALETTES.size() - 1)]
		areas.append(a)
	if not areas.is_empty():
		zone_index = areas[0].index

	_build_ground()
	_build_path()
	for a in areas:
		_build_area_shell(a)
	if areas.size() > 0:
		_build_valley(areas[0])
	if areas.size() > 1:
		_build_quarry(areas[1])
	World.zone_progress_changed.connect(func(zone: int, progress: int) -> void:
		for a in areas:
			if zone == a.index:
				a.target = progress
		_update_gates())
	World.reset.connect(_sync_progress)
	_sync_progress()


func set_environment(env: Environment) -> void:
	_env = env


## 그 자리가 속한 오염 구역. 없으면 null.
func area_at(pos: Vector3) -> Area:
	for a in areas:
		if a.bounds.has_point(Vector2(pos.x, pos.z)):
			return a
	return null


func area_of_zone(zone: int) -> Area:
	for a in areas:
		if a.index == zone:
			return a
	return null


func config() -> Dictionary:
	var rows: Array = []
	for a in areas:
		rows.append({"zone": a.index, "requires": a.requires, "spawn_points": a.spawn_points, "spawn_types": a.spawn_types,
				"boss": a.boss, "boss_spawn": a.boss_spawn, "boss_radius": a.boss_radius})
	return {"zones": rows}


## 길찾기 메시를 굽는다(호스트만). 오염 구역 안쪽만 대상으로 하고, 구역마다 따로 굽는다.
func bake() -> RID:
	for i in areas.size():
		var b := areas[i].bounds
		var nav := NavigationMesh.new()
		nav.cell_size = 0.25
		nav.cell_height = 0.25
		nav.agent_radius = 0.75
		nav.agent_height = 1.5
		nav.agent_max_climb = 0.25
		nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		nav.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
		nav.geometry_source_group_name = NAV_GROUP
		nav.filter_baking_aabb = AABB(Vector3(b.position.x, -1.0, b.position.y), Vector3(b.size.x, 9.0, b.size.y))
		var region: NavigationRegion3D = self
		if i > 0:
			region = NavigationRegion3D.new()
			add_child(region)
			_extra_regions.append(region)
		region.navigation_mesh = nav
		region.bake_navigation_mesh(false)
	return get_navigation_map()


# ---------------------------------------------------------------------------
# 지형
# ---------------------------------------------------------------------------

func _build_ground() -> void:
	# 전체 바닥. 윗면이 y = 0 이어야 격자 칸과 맞는다. 정원 남쪽의 훈련장부터 골짜기 북쪽 끝까지.
	_box(Vector3(0, -0.5, -110), Vector3(460, 1, 600), Color(0.34, 0.42, 0.36), null)


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
	_sign(Vector3(40, 0, -44), "녹슨 채석장 →")
	_sign(Vector3(100, 0, -45), "녹슨 채석장 →")


## 구역의 바닥(색이 바뀌는 부분), 둘레 절벽, 입구, 비콘 자리 표시.
func _build_area_shell(a: Area) -> void:
	var b := a.bounds
	var c := b.get_center()
	var ground: Color = a.palette[0]
	var rock: Color = a.palette[2]
	# 전체 바닥보다 살짝 높다.
	_box(Vector3(c.x, -0.22, c.y), Vector3(b.size.x, 0.5, b.size.y), ground, a.ground_mats)
	# 절벽 네 면. 입구가 있는 면은 그 자리만 비운다.
	var h := WALL_HEIGHT
	for side in 4:
		var along_x := side < 2                      # 0: 북(z 최소), 1: 남(z 최대), 2: 서(x 최소), 3: 동(x 최대)
		var fixed: float = [b.position.y, b.end.y, b.position.x, b.end.x][side]
		var lo := (b.position.x if along_x else b.position.y) - 2.0
		var hi := (b.end.x if along_x else b.end.y) + 2.0
		var e_fixed := a.entrance.z if along_x else a.entrance.x
		var e_along := a.entrance.x if along_x else a.entrance.z
		var spans: Array[Vector2] = [Vector2(lo, hi)]
		if is_equal_approx(e_fixed, fixed):
			spans = [Vector2(lo, e_along - ENTRANCE_WIDTH * 0.5), Vector2(e_along + ENTRANCE_WIDTH * 0.5, hi)]
		for span in spans:
			var mid := (span.x + span.y) * 0.5
			var length := span.y - span.x
			if along_x:
				_box(Vector3(mid, h * 0.5, fixed), Vector3(length, h, 4), rock, a.rock_mats)
			else:
				_box(Vector3(fixed, h * 0.5, mid), Vector3(4, h, length), rock, a.rock_mats)
	# 선행 구역이 있으면 입구를 막아 둔다.
	if a.requires >= 0:
		var on_x_side := is_equal_approx(a.entrance.x, b.position.x) or is_equal_approx(a.entrance.x, b.end.x)
		var size := Vector3(3, h, ENTRANCE_WIDTH) if on_x_side else Vector3(ENTRANCE_WIDTH, h, 3)
		a.gate = _box(a.entrance + Vector3(0, h * 0.5, 0), size, Color(0.25, 0.5, 0.48), null)
		var out := (a.entrance - Vector3(c.x, 0, c.y)).normalized() * 3.0
		var label := _sign(Vector3.ZERO, "%s을(를) 복원하면 열립니다" % Registry.db.zones[a.requires].display_name)
		label.reparent(a.gate, false)
		label.position = out + Vector3(0, 1.6 - h * 0.5, 0)
	# 비콘 자리 표시.
	if a.index >= 0:
		var site := Vector3(Registry.db.zones[a.index].beacon_site) + Vector3(1.5, 0, 1.5)
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


func _build_valley(a: Area) -> void:
	var rock: Color = a.palette[2]
	# 엄폐용 바위: 낮은 것(1.2m), 올라탈 수 있는 것(2m), 매달려야 하는 것(3.5m).
	for spec: Array in [
			[-22, -204, 5, 1.2, 1.2], [18, -206, 1.2, 1.2, 5], [-6, -216, 4, 1.2, 1.2], [30, -224, 5, 1.2, 1.2],
			[-36, -232, 1.2, 1.2, 5], [8, -242, 6, 1.2, 1.2], [-20, -250, 4, 1.2, 1.2], [28, -254, 1.2, 1.2, 5],
			[-8, -272, 5, 1.2, 1.2], [20, -268, 4, 1.2, 1.2], [-40, -268, 5, 1.2, 1.2], [42, -238, 4, 1.2, 1.2],
			[-28, -214, 6, 2.0, 6], [36, -270, 6, 2.0, 6], [-44, -286, 7, 3.5, 7], [46, -206, 6, 3.5, 6],
			[2, -228, 3, 2.0, 3], [-14, -262, 3, 3.5, 3]]:
		_box(Vector3(spec[0], spec[3] * 0.5, spec[1]), Vector3(spec[2], spec[3], spec[4]), rock, a.rock_mats)
	# 우두머리의 터: 돌진을 유도해 부딪히게 할 기둥 넷.
	for px: float in [-13.0, 13.0]:
		for pz: float in [-300.0, -318.0]:
			_box(Vector3(px, 3.0, pz), Vector3(2.4, 6, 2.4), rock, a.rock_mats)
	_sign(Vector3(0, 0, -288), "수호체의 터")
	_scatter_flora(a, 26, 120)


## 녹슨 채석장: 정원 동쪽. 서쪽 입구로 들어가 동쪽 끝의 터까지. 포탑의 사선을 끊을 엄폐물이 촘촘하다.
func _build_quarry(a: Area) -> void:
	var rock: Color = a.palette[2]
	# 엄폐용 돌덩이: 낮은 것(1.2m), 올라탈 수 있는 것(2m), 매달려야 하는 것(3.5m).
	for spec: Array in [
			[132, -60, 1.2, 1.2, 5], [138, -50, 5, 1.2, 1.2], [146, -44, 1.2, 1.2, 5], [156, -78, 5, 1.2, 1.2],
			[160, -48, 4, 1.2, 1.2], [176, -40, 1.2, 1.2, 5], [180, -74, 5, 1.2, 1.2], [172, -22, 5, 1.2, 1.2],
			[150, -92, 1.2, 1.2, 5], [186, -58, 1.2, 1.2, 5], [164, -110, 5, 1.2, 1.2], [134, -20, 4, 2.0, 4],
			[198, -104, 6, 2.0, 6], [128, -104, 6, 3.5, 6], [176, -88, 3, 3.5, 3], [210, -8, 6, 3.5, 6]]:
		_box(Vector3(spec[0], spec[3] * 0.5, spec[1]), Vector3(spec[2], spec[3], spec[4]), rock, a.rock_mats)
	# 계단식으로 깎인 채석 단(남서쪽 구석). 위에서 채석장 전체가 내려다보인다.
	_box(Vector3(130, 1.0, -8), Vector3(16, 2, 12), rock, a.rock_mats)
	_box(Vector3(127, 3.0, -6), Vector3(8, 2, 8), rock, a.rock_mats)
	# 거신의 터: 돌진을 유도해 부딪히게 할 기둥 넷.
	for px: float in [194.0, 214.0]:
		for pz: float in [-30.0, -54.0]:
			_box(Vector3(px, 3.0, pz), Vector3(2.4, 6, 2.4), rock, a.rock_mats)
	_sign(Vector3(188, 0, -42), "채석 거신의 터")
	_scatter_flora(a, 14, 90)


## 식생: 죽은 나무(처음부터 보임)와, 복원이 진행되며 나타나는 풀·꽃·나무.
func _scatter_flora(a: Area, dead: int, alive: int) -> void:
	for i in dead:
		_dead_tree(_area_point(a))
	for i in alive:
		a.flora.append([_plant(_area_point(a), i), [25, 50, 75, 100][i % 4]])


func _area_point(a: Area) -> Vector3:
	var b := a.bounds
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
	if World.sim == null:
		return
	for a in areas:
		if a.index >= 0:
			a.target = World.sim.zone_progress(a.index)
			a.shown = -1.0
	_update_gates()


## 선행 구역이 복원됐으면 입구를 막던 벽을 치운다.
func _update_gates() -> void:
	if World.sim == null:
		return
	for a in areas:
		if a.gate != null and a.requires >= 0 and World.sim.zone_restored(a.requires):
			a.gate.queue_free()
			a.gate = null


func _process(delta: float) -> void:
	# 진행도 숫자를 화면의 색과 식생으로 서서히 옮긴다.
	for a in areas:
		if is_equal_approx(a.shown, a.target):
			continue
		a.shown = a.target if a.shown < 0.0 else move_toward(a.shown, a.target, delta * 12.0)
		var t := clampf(a.shown / 100.0, 0.0, 1.0)
		for m in a.ground_mats:
			_tint(m, (a.palette[0] as Color).lerp(a.palette[1], t))
		for m in a.rock_mats:
			_tint(m, (a.palette[2] as Color).lerp(a.palette[3], t))
		for f: Array in a.flora:
			var node: Node3D = f[0]
			if not node.visible and a.shown >= float(f[1]):
				node.visible = true
				node.create_tween().tween_property(node, "scale", Vector3.ONE, 0.8).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
			elif node.visible and a.shown < float(f[1]):
				node.visible = false
				node.scale = Vector3.ONE * 0.01


## 플레이어가 오염 구역 안에 있을 때, 복원이 덜 된 만큼 탁한 안개가 낀다.
func update_atmosphere(player_pos: Vector3, delta: float) -> void:
	if _env == null:
		return
	var a := area_at(player_pos)
	var blight := 0.0
	var fog := Color(0.42, 0.34, 0.44)
	if a != null:
		blight = 1.0 - clampf(a.shown / 100.0, 0.0, 1.0)
		fog = a.palette[4]
	_env.fog_enabled = true
	_env.fog_density = lerpf(_env.fog_density, 0.022 * blight, 1.0 - exp(-1.5 * delta))
	_env.fog_light_color = _env.fog_light_color.lerp(fog.lerp(Color(0.7, 0.8, 0.85), 1.0 - blight), 1.0 - exp(-2.0 * delta))


func _tint(m: ShaderMaterial, color: Color) -> void:
	m.set_shader_parameter(&"base_color", color)
	m.set_shader_parameter(&"line_color", color.darkened(0.3))


func _sign(pos: Vector3, text: String) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos + Vector3(0, 1.6, 0)
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.pixel_size = 0.008
	l.font_size = 48
	l.outline_size = 12
	add_child(l)
	return l


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
