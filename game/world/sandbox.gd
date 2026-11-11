extends Node3D
## 개발용 샌드박스: 멀티플레이 뼈대와 공장 시뮬레이션을 눈으로 확인하는 회색 상자 맵.
## 건축 모드(M2)가 생기기 전까지 쓰는 임시 조작:
##   B 조준한 칸에 저장소 · N 기준 생산 라인 한 벌 건설 · X 조준한 구조물 철거
## 실행 인자 `--nettest=host|client|late|visitor` 는 자동 통합 점검용이다(tools/net_test.sh).

const GRID_SHADER := preload("res://game/range/grid.gdshader")
const MAIN_SCENE := "res://game/main.tscn"
const STATE_INTERVAL := 0.05
const NETTEST_END_TICK := 250

var player: PlayerController
var hud: Hud
var view: StructureView
var remotes: RemotePlayers

var _state_timer: float = 0.0
var _last_reject: String = ""
var _nettest: String = ""
var _nettest_start: int = -1
var _node_markers: Node3D


func _ready() -> void:
	InputSetup.register()
	_build_environment()
	_node_markers = Node3D.new()
	add_child(_node_markers)
	view = StructureView.new()
	add_child(view)
	remotes = RemotePlayers.new()
	add_child(remotes)

	var sfx := Sfx.new()
	add_child(sfx)
	var fx := Fx.new()
	add_child(fx)
	player = PlayerController.new()
	player.sfx = sfx
	player.fx = fx
	add_child(player)
	# 접속한 순서대로 조금씩 떨어진 자리에서 시작한다.
	player.teleport(Vector3(float(Net.players.size() - 1) * 1.5, 0.05, 0), 0.0)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.player = player
	hud.help_lines = [
		"WASD 이동 · Shift 달리기 · Space 점프 (턱 앞에서 앞으로 밀면 올라타기) · Ctrl 앉기/슬라이딩",
		"B 저장소 설치 · N 기준 생산 라인 건설 · X 조준한 구조물 철거 · Esc 마우스 풀기",
	]
	layer.add_child(hud)
	player.hit_confirmed.connect(hud.on_hit)

	World.reset.connect(_refresh_nodes)
	World.request_rejected.connect(func(reason: String) -> void: _last_reject = reason)
	Net.disconnected.connect(_on_disconnected)
	_refresh_nodes()

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nettest="):
			_nettest = arg.trim_prefix("--nettest=")
			player.force_active = true
			if _nettest == "host":
				Net.role_overrides["visitor"] = Net.Role.VISITOR
			World.ticked.connect(_nettest_tick)
		elif arg.begins_with("--shot="):
			_shot(arg.trim_prefix("--shot="))


func _on_disconnected(reason: String) -> void:
	if _nettest != "":
		print("NETTEST %s disconnected: %s" % [_nettest, reason])
		get_tree().quit(1)
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MAIN_SCENE)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_help"):
		hud.toggle_help()
	elif event.is_action_pressed(&"toggle_fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not player.is_active():
		return
	elif event.is_action_pressed(&"dev_build_box"):
		var aim := _aim()
		if not aim.is_empty():
			var p: Vector3 = aim["position"] + aim["normal"] * 0.05
			World.request_place(&"storage", Vector3i(floori(p.x), maxi(floori(p.y), 0), floori(p.z)), 0)
	elif event.is_action_pressed(&"dev_build_line"):
		build_next_line()
	elif event.is_action_pressed(&"dev_remove"):
		var aim := _aim()
		if not aim.is_empty():
			var id := StructureView.structure_id_of(aim["collider"])
			if id != 0:
				World.request_remove(id)


func _aim() -> Dictionary:
	var from := player.camera.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - player.camera.global_basis.z * 15.0)
	q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


## 아직 비어 있는 첫 번째 광맥 자리에 기준 생산 라인을 짓는다. 지었으면 true.
func build_next_line() -> bool:
	for origin in World.DEV_LINE_ORIGINS:
		if not World.sim.occupancy.has(origin + (ReferenceLine.MACHINES[0][1] as Vector3i)):
			build_line(origin)
			return true
	_last_reject = "빈 광맥 자리가 없음"
	return false


func build_line(origin: Vector3i) -> void:
	for m in ReferenceLine.MACHINES:
		World.request_place(m[0], origin + (m[1] as Vector3i), 0)
	for i in ReferenceLine.BELTS.size():
		World.request_place_belt(&"belt", ReferenceLine.belt_path(origin, i))
	World.request_insert_at(origin + ReferenceLine.GENERATOR_CELL, &"biofuel", 10)


func _process(delta: float) -> void:
	_state_timer += delta
	if _state_timer >= STATE_INTERVAL:
		_state_timer = 0.0
		World.send_player_state(player.global_position, player.yaw, player.pitch, player.crouching)
	if player.global_position.y < -20.0:
		player.teleport(Vector3(0, 0.05, 0), 0.0)
	if World.sim == null:
		return
	var role: String = ["소유자", "건설자", "방문자"][Net.role_of(Net.my_id())]
	var mode := "호스트" if Net.is_host() else "참가자"
	hud.message = "%s · %s · 접속 %d명 · 틱 %d · 구조물 %d%s%s" % [
		mode, role, Net.players.size(), World.sim.tick_count, World.sim.structures.size(),
		" · 재동기화 %d회" % World.resync_count if World.resync_count > 0 else "",
		" · 거절: %s" % _last_reject if _last_reject != "" else ""]


func _refresh_nodes() -> void:
	for c in _node_markers.get_children():
		c.queue_free()
	if World.sim == null:
		return
	for cell: Vector3i in World.sim.nodes:
		var mi := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 1.6
		mesh.bottom_radius = 1.6
		mesh.height = 0.06
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.35, 0.25)
		mi.material_override = mat
		mi.position = Vector3(cell) + Vector3(0.5, 0.03, 0.5)
		_node_markers.add_child(mi)


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.25, 0.45, 0.75)
	sky_mat.sky_horizon_color = Color(0.72, 0.8, 0.85)
	sky_mat.ground_bottom_color = Color(0.2, 0.25, 0.22)
	sky_mat.ground_horizon_color = Color(0.72, 0.8, 0.85)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)
	# 바닥. 윗면이 y = 0 이어야 격자 칸과 맞는다.
	var body := StaticBody3D.new()
	body.position = Vector3(0, -0.5, 0)
	var shape := BoxShape3D.new()
	shape.size = Vector3(400, 1, 400)
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mesh := BoxMesh.new()
	mesh.size = shape.size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = GRID_SHADER
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)


# ---------------------------------------------------------------------------
# 자동 통합 점검. 모든 프로세스가 같은 틱에 상태 해시를 출력하고, 스크립트가 비교한다.
# ---------------------------------------------------------------------------

func _nettest_tick(tick: int) -> void:
	if _nettest_start < 0:
		_nettest_start = tick
	var since := tick - _nettest_start
	match _nettest:
		"host":
			if tick == 20:
				build_line(World.DEV_LINE_ORIGINS[0])
			elif tick == 120:
				build_line(World.DEV_LINE_ORIGINS[1])
				# 가동 중인 첫 라인의 벨트 하나를 철거한다.
				var belt_cell := ReferenceLine.belt_path(World.DEV_LINE_ORIGINS[0], 5)[0]
				World.request_remove(World.sim.occupancy.get(belt_cell, 0))
		"client":
			if since == 30:
				World.request_place(&"storage", Vector3i(-20, 0, -10), 0)
		"visitor":
			if since == 10:
				World.request_place(&"storage", Vector3i(-25, 0, -10), 0)
	if tick == NETTEST_END_TICK:
		print("NETTEST %s hash=%s structures=%d players=%d remote_seen=%d resyncs=%d rejected=%s" % [
			_nettest, World.sim.state_hash(), World.sim.structures.size(), Net.players.size(),
			remotes.seen.size(), World.resync_count, _last_reject if _last_reject != "" else "-"])
	# 호스트는 클라이언트가 마지막 틱을 받을 시간을 주고 끝낸다.
	if tick == NETTEST_END_TICK + (20 if _nettest == "host" else 0):
		get_tree().quit(0)


## 기준 라인을 짓고 잠시 돌린 뒤 화면을 저장한다(렌더링 확인용).
func _shot(path: String) -> void:
	player.force_active = true
	build_line(World.DEV_LINE_ORIGINS[1])
	player.teleport(Vector3(-2, 6, -14), deg_to_rad(8.0))
	player.gravity = 0.0
	player.pitch = deg_to_rad(-22.0)
	World.remote_player_state.emit(99, Vector3(-4, 0, -20), 0.6, 0.0, false)
	while World.sim.tick_count < 300:
		await get_tree().physics_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
