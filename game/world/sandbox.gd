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
var _nettest_died: int = 0
var _nettest_was_downed: bool = false
var _node_markers: Node3D
var yard: CombatYard
var combat_view: CombatView
var build: BuildMode
var panel: StructurePanel


func _ready() -> void:
	InputSetup.register()
	_build_environment()
	yard = CombatYard.new()
	add_child(yard)
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
	player.use_world_ammo = true
	add_child(player)
	# 전에 있던 자리에서 시작한다. 처음이면 접속한 순서대로 조금씩 떨어진 자리.
	var spawn := World.saved_spawn(World.my_key()) if Net.is_host() else World.my_spawn
	if spawn.is_empty():
		player.teleport(Vector3(float(Net.players.size() - 1) * 1.5, 0.05, 0), 0.0)
	else:
		player.teleport(spawn[0], spawn[1])
	World.spawn_assigned.connect(func(pos: Vector3, yaw: float) -> void: player.teleport(pos, yaw))
	Save.saved.connect(func(ok: bool, message: String) -> void:
		hud.toast("저장했습니다" if ok else "저장 실패: %s" % message))

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.player = player
	hud.help_lines = [
		"WASD 이동 · Shift 달리기 · Space 점프 (턱 앞에서 앞으로 밀면 올라타기) · Ctrl 앉기/슬라이딩",
		"좌클릭 사격 · 우클릭 조준 · R 재장전 · 1/2/3 무기 · G 수류탄 · E 동료 일으키기",
		"벽 옆에서 달리며 점프 = 벽 달리기, 다시 점프 = 벽 차기 · 뒤쪽(+Z) 담장 안이 전투 구역",
		"B 건축 모드 (Tab 탭 · 휠 선택 · R 회전 · 좌클릭 설치 · X 철거 · F 같은 것 고르기 · Z 되돌리기 · Esc 닫기) · E 설비 열기",
		"노란 띠 안쪽이 건축 구역. 화살표는 설비의 입력(파랑)과 출력(주황)",
		"N 기준 생산 라인 한 벌 · F9 부하 시험(설비 504개를 한 번에, 프레임 측정용) — 개발용, 호스트만 · Esc 마우스 풀기",
		"F6 저장 · F10 저장하고 나가기 (5분마다 자동 저장)",
	]
	layer.add_child(hud)
	hud.collapse_help()
	player.hit_confirmed.connect(hud.on_hit)

	build = BuildMode.new()
	build.player = player
	build.hud = hud
	add_child(build)
	panel = StructurePanel.new()
	layer.add_child(panel)
	combat_view = CombatView.new()
	combat_view.player = player
	combat_view.hud = hud
	combat_view.fx = fx
	combat_view.sfx = sfx
	combat_view.yard = yard
	add_child(combat_view)
	# 길찾기 메시는 적을 움직이는 호스트만 필요하다.
	var nav_map := yard.bake() if Net.is_host() else RID()
	Combat.bind_scene(self, Vector3.ZERO, nav_map, yard.spawn_points, player.get_rid())

	World.reset.connect(_refresh_nodes)
	World.request_rejected.connect(func(reason: String) -> void: _last_reject = reason)
	Net.disconnected.connect(_on_disconnected)
	_refresh_nodes()

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nettest="):
			_nettest = arg.trim_prefix("--nettest=")
			player.force_active = true
			Combat.auto_spawn = false
			Combat.enemy_died.connect(func(_i: int, _p: Vector3, _k: int) -> void: _nettest_died += 1)
			if _nettest == "host":
				Net.role_overrides["visitor"] = Net.Role.VISITOR
			World.ticked.connect(_nettest_tick)
		elif arg.begins_with("--yardshot="):
			_yard_shot(arg.trim_prefix("--yardshot="))
		elif arg.begins_with("--savetest="):
			_save_test(arg.trim_prefix("--savetest="))
		elif arg.begins_with("--buildshot="):
			_build_shot(arg.trim_prefix("--buildshot="))
		elif arg == "--buildtest":
			_build_test()
		elif arg == "--combattest":
			_combat_test()
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
	if panel.visible:
		if event.is_action_pressed(&"interact") or event.is_action_pressed(&"pause"):
			_close_panel()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"pause"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_help"):
		hud.toggle_help()
	elif event.is_action_pressed(&"save_game"):
		if not Net.is_host():
			hud.toast("저장은 호스트가 합니다")
		elif not Save.save_now():
			hud.toast("이미 저장하는 중입니다")
	elif event.is_action_pressed(&"save_and_exit"):
		Net.leave()
	elif event.is_action_pressed(&"dev_stress"):
		if not Net.is_host():
			hud.toast("부하 시험은 호스트만 (개발용)")
		else:
			var built := World.dev_stress()
			hud.toast("부하 시험: 설비 %d개를 지었습니다. 왼쪽 위 FPS를 보세요" % built if built > 0 else "부하 시험 공장은 이미 지어져 있습니다")
			player.teleport(Vector3(0, 12, 84), PI)
	elif event.is_action_pressed(&"toggle_fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not player.is_active():
		return
	elif event.is_action_pressed(&"interact") and not build.active and not combat_view.reviving():
		var aim := _aim()
		if not aim.is_empty() and (aim["position"] as Vector3).distance_to(player.global_position) < 6.0:
			open_panel(StructureView.structure_id_of(aim["collider"]))
	elif event.is_action_pressed(&"dev_build_line"):
		build_next_line()


func open_panel(id: int) -> bool:
	if not panel.open(id):
		return false
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	return true


func _close_panel() -> void:
	panel.close()
	player.input_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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


## 개발용(호스트만): 재료를 지급받고 기준 생산 라인을 한 번에 짓는다.
func build_line(origin: Vector3i) -> void:
	if not Net.is_host():
		_last_reject = "기준 라인 건설은 호스트만 (개발용)"
		return
	World.grant(1, {"iron_ingot": 80, "biofuel": 10})
	for m in ReferenceLine.MACHINES:
		World.request_place(m[0], origin + (m[1] as Vector3i), 0)
	for i in ReferenceLine.BELTS.size():
		World.request_place_belt(&"belt", ReferenceLine.belt_path(origin, i))
	var gen: int = World.sim.occupancy.get(origin + ReferenceLine.GENERATOR_CELL, 0)
	if gen != 0:
		# 멀리서 넣는 것이므로 거리 검사를 거치지 않고 이벤트로 직접 넣는다.
		World._emit_event("insert", [gen, "biofuel", 10, World.my_key()])


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
	hud.message = "%s · %s · 접속 %d명 · 틱 %d · 구조물 %d · 적 %d%s%s" % [
		mode, role, Net.players.size(), World.sim.tick_count, World.sim.structures.size(), Combat.enemies.size(),
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
	# 건축 구역: 높은 단은 실제 지형(발판과 경사로)으로, 가장자리는 띠로 표시한다.
	for zone in World.sim.build_zones:
		var zx := float(zone[0])
		var zz := float(zone[1])
		var w := float(zone[2])
		var d := float(zone[3])
		var gy := float(zone[4])
		if gy > 0.0:
			_zone_box(Vector3(zx + w * 0.5, gy * 0.5, zz + d * 0.5), Vector3(w, gy, d), Color(0.4, 0.46, 0.38), Vector3.ZERO, true)
			var run := gy * 2.0
			_zone_box(Vector3(zx - run * 0.5, gy * 0.5 - 0.15, zz + d * 0.5), Vector3(sqrt(run * run + gy * gy), 0.3, 6.0),
				Color(0.5, 0.46, 0.4), Vector3(0, 0, rad_to_deg(atan2(gy, run))), true)
		var edge := Color(0.95, 0.85, 0.35)
		var y := gy + 0.03
		_zone_box(Vector3(zx + w * 0.5, y, zz), Vector3(w, 0.06, 0.25), edge, Vector3.ZERO, false)
		_zone_box(Vector3(zx + w * 0.5, y, zz + d), Vector3(w, 0.06, 0.25), edge, Vector3.ZERO, false)
		_zone_box(Vector3(zx, y, zz + d * 0.5), Vector3(0.25, 0.06, d), edge, Vector3.ZERO, false)
		_zone_box(Vector3(zx + w, y, zz + d * 0.5), Vector3(0.25, 0.06, d), edge, Vector3.ZERO, false)


func _zone_box(pos: Vector3, size: Vector3, color: Color, rot_deg: Vector3, solid: bool) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = GRID_SHADER
	mat.set_shader_parameter(&"base_color", color)
	mat.set_shader_parameter(&"line_color", color.darkened(0.25))
	mi.material_override = mat
	var holder: Node3D = StaticBody3D.new() if solid else Node3D.new()
	holder.position = pos
	holder.rotation_degrees = rot_deg
	holder.add_child(mi)
	if solid:
		var shape := BoxShape3D.new()
		shape.size = size
		var col := CollisionShape3D.new()
		col.shape = shape
		holder.add_child(col)
	_node_markers.add_child(holder)


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
			elif tick == 30:
				# 누구의 감지 범위에도 들지 않는 먼 곳에 과녁용 적을 하나 둔다.
				Combat.spawn_enemy(&"spitter", Vector3(0, 0.1, 68))
			elif tick == 150:
				Combat.damage_player(_peer_named("late"), 9999.0)
			elif tick == 120:
				build_line(World.DEV_LINE_ORIGINS[1])
				# 가동 중인 첫 라인의 벨트 하나를 철거한다.
				var belt_cell := ReferenceLine.belt_path(World.DEV_LINE_ORIGINS[0], 5)[0]
				World.request_remove(World.sim.occupancy.get(belt_cell, 0))
		"client":
			if since == 30:
				World.request_place(&"storage", Vector3i(-20, 0, -10), 0)
				# 클라이언트가 보내는 다른 종류의 요청들: 장식 놓기, 탄약 쓰기, 밭 만들고 심기.
				World.request_place_free(&"lamp", player.global_position + Vector3(1, 0, 1), 30)
				World.request("consume", ["rifle_ammo", 10])
				World.request_place(&"plot", Vector3i(4, 0, 4), 0)
			elif since == 40:
				World.request("plant", [World.sim.occupancy.get(Vector3i(4, 0, 4), 0), "glowleaf_seed"])
			elif since >= 110 and since < 130 and since % 2 == 0 and not Combat.enemies.is_empty():
				# 적을 맞혔다고 보고한다(체력 40, 먼 거리 몸통 7.2 → 6발).
				Combat.begin_shot(&"rifle", player.global_position, Vector3(0, 1, 68))
				Combat.queue_hit(Combat.enemies.keys()[0], false)
			elif since == 150:
				Combat.request_revive(_peer_named("late"))
		"visitor":
			if since == 10:
				World.request_place(&"storage", Vector3i(-25, 0, -10), 0)
				# 한 프레임에 세 번 보고: 첫 번째만 받아들여져야 한다.
				for i in 3:
					Combat._req_hits.rpc_id(1, "rifle", PackedInt32Array([1]), PackedInt32Array([0]))
	var mine := Combat.my_vitals()
	if mine != null and mine.state == Combat.PState.DOWNED:
		_nettest_was_downed = true
	if tick == NETTEST_END_TICK:
		print("NETTEST %s hash=%s structures=%d players=%d remote_seen=%d resyncs=%d rejected=%s enemies=%d died_seen=%d bad_shots=%d downed=%s hp=%d" % [
			_nettest, World.sim.state_hash(), World.sim.structures.size(), Net.players.size(),
			remotes.seen.size(), World.resync_count, _last_reject if _last_reject != "" else "-",
			Combat.enemies.size(), _nettest_died, Combat.rejected_shots, _nettest_was_downed,
			roundi(mine.hp) if mine != null else -1])
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


# ---------------------------------------------------------------------------
# 전투 자동 점검 (혼자, 화면 없이): `godot --headless -- --single --combattest`
# ---------------------------------------------------------------------------

func _combat_test() -> void:
	var errors: PackedStringArray = []
	player.force_active = true
	Combat.auto_spawn = false
	await _wait(0.5)

	# 길찾기: 엄폐물을 사이에 둔 두 점 사이에 경로가 나온다.
	var path := Combat.find_path(Vector3(-3, 0, 33), Vector3(-3, 0, 39))
	if path.size() < 2:
		errors.append("길찾기 경로가 없음 (점 %d개)" % path.size())

	# 돌진형: 다가와서 때린다.
	player.teleport(Vector3(0, 0.05, 20), PI)
	await _wait(0.3)
	var crawler := Combat.spawn_enemy(&"crawler", Vector3(0, 0.1, 34))
	await _wait(5.0)
	var me := Combat.my_vitals()
	if me.hp >= CombatRules.MAX_HP:
		errors.append("돌진형이 5초 안에 피해를 주지 못함 (거리 %.1f)" % crawler.global_position.distance_to(player.global_position))

	# 사격: 보고 → 호스트 검증 → 처치 → 전리품 굴림.
	player.equip_by_id(&"rifle")
	await _wait(0.4)
	var shots := 0
	while is_instance_valid(crawler) and Combat.enemies.has(crawler.net_id) and shots < 40:
		_aim_at(crawler.global_position + Vector3(0, 0.5, 0))
		await get_tree().process_frame
		player.gun.mag = 30
		player.gun.cooldown = 0.0
		player.gun.bloom = 0.0
		player._shoot()
		shots += 1
		await _wait(0.12)
	if Combat.kills != 1:
		errors.append("소총 %d발로 돌진형을 처치하지 못함" % shots)
	elif shots < 4 or shots > 12:
		errors.append("돌진형 처치에 %d발 (체력 60, 피해 12 → 5발 안팎이어야 함)" % shots)

	# 검증: 연사 간격보다 빠른 보고, 모르는 무기는 거절된다.
	var dummy := Combat.spawn_enemy(&"spitter", Vector3(25, 0.1, 70))
	var rejected_before := Combat.rejected_shots
	Combat._do_hits(1, "rifle", PackedInt32Array([dummy.net_id]), PackedInt32Array([0]))
	Combat._do_hits(1, "rifle", PackedInt32Array([dummy.net_id]), PackedInt32Array([0]))
	Combat._do_hits(1, "nope", PackedInt32Array([dummy.net_id]), PackedInt32Array([0]))
	Combat._do_hits(1, "rifle", PackedInt32Array([dummy.net_id, dummy.net_id]), PackedInt32Array([0, 0]))
	if Combat.rejected_shots - rejected_before != 3:
		errors.append("잘못된 사격 보고 3건 중 %d건만 거절됨" % (Combat.rejected_shots - rejected_before))
	if absf(dummy.hp - (dummy.max_hp - CombatRules.hit_damage(Combat.weapons[&"rifle"], dummy.global_position.distance_to(player.global_position), false))) > 0.01:
		errors.append("거절된 보고가 피해를 줌 (체력 %.1f / %.1f)" % [dummy.hp, dummy.max_hp])
	Combat._damage_enemy(dummy, 9999.0, 1)

	# 원거리형: 시야가 트인 곳에서 침을 쏴 맞힌다.
	await _wait(5.5)   # 체력 회복 대기
	player.teleport(Vector3(-20, 0.05, 20), PI)
	await _wait(0.3)
	var hp_before := Combat.my_vitals().hp
	var spitter := Combat.spawn_enemy(&"spitter", Vector3(-20, 0.1, 26))
	await _wait(4.5)
	if Combat.my_vitals().hp >= hp_before:
		errors.append("원거리형이 4.5초 안에 맞히지 못함")
	if is_instance_valid(spitter) and spitter.global_position.distance_to(player.global_position) < 8.0:
		errors.append("원거리형이 거리를 벌리지 않음 (%.1fm)" % spitter.global_position.distance_to(player.global_position))
	if is_instance_valid(spitter):
		Combat._damage_enemy(spitter, 9999.0, 1)

	# 수류탄: 뭉쳐 있는 적 셋에게 던진다.
	var kills_before := Combat.kills
	player.teleport(Vector3(10, 0.05, 20), PI)
	await _wait(0.3)
	# 자리를 지키는 원거리형으로 시험한다(돌진형은 폭발 전에 달려 나온다).
	for i in 3:
		Combat.spawn_enemy(&"spitter", Vector3(9.0 + i, 0.1, 34))
	_aim_at(Vector3(10, 0.3, 34))
	await get_tree().process_frame
	var forward := -player.camera.global_basis.z
	Combat.request_throw(player.camera.global_position + forward * 0.6, forward * CombatView.THROW_SPEED + Vector3(0, 4, 0))
	await _wait(2.6)
	if Combat.kills - kills_before < 2:
		errors.append("수류탄으로 %d마리만 처치" % (Combat.kills - kills_before))
	if Combat.my_grenades != CombatRules.GRENADE_MAX - 1:
		errors.append("수류탄 개수 %d (기대 %d)" % [Combat.my_grenades, CombatRules.GRENADE_MAX - 1])
	for id: int in Combat.enemies.keys():
		Combat._damage_enemy(Combat.enemies[id], 9999.0, 1)

	# 전리품: 지금까지의 처치로 뭔가는 얻었어야 한다(확률이지만 6마리 모두 꽝일 확률은 1% 미만).
	if World.my_count(&"scrap") + World.my_count(&"taint_crystal") == 0:
		errors.append("처치 %d회 동안 전리품이 하나도 없음" % Combat.kills)

	# 쓰러짐 → 혼자면 3초 뒤 시작 지점에서 다시 일어난다.
	Combat.damage_player(1, 9999.0)
	await _wait(0.2)
	if not player.downed or player.is_active():
		errors.append("체력 0인데 쓰러지지 않음")
	await _wait(CombatRules.SOLO_RESPAWN_SECONDS + 0.5)
	if player.downed or Combat.my_vitals().hp < CombatRules.MAX_HP or player.global_position.length() > 2.0:
		errors.append("다시 일어나지 못함 (쓰러짐=%s, 위치 %s)" % [player.downed, player.global_position])

	if errors.is_empty():
		print("COMBATTEST OK (처치 %d)" % Combat.kills)
	else:
		for e in errors:
			print("COMBATTEST FAIL: %s" % e)
	get_tree().quit(0 if errors.is_empty() else 1)


func _peer_named(peer_name: String) -> int:
	for peer: int in Net.players:
		if (Net.players[peer] as Dictionary).get("name", "") == peer_name:
			return peer
	return -1


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _aim_at(point: Vector3) -> void:
	var d := point - player.camera.global_position
	player.yaw = atan2(-d.x, -d.z)
	player.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	player._recoil = Vector2.ZERO
	player._recoil_target = Vector2.ZERO
	player._shake = 0.0


## 전투 구역 화면을 저장한다(렌더링 확인용).
func _yard_shot(path: String) -> void:
	player.force_active = true
	Combat.auto_spawn = false
	player.teleport(Vector3(4, 0.05, 17), PI + 0.25)
	player.pitch = deg_to_rad(-4.0)
	await _wait(0.5)
	Combat.spawn_enemy(&"crawler", Vector3(2, 0.1, 27))
	Combat.spawn_enemy(&"spitter", Vector3(-4, 0.1, 40))
	Combat.spawn_enemy(&"spitter", Vector3(8, 0.1, 34))
	Combat.damage_player(1, 35.0)
	await _wait(1.6)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


## 저장/이어하기 점검 (tools/save_test.sh). write: 공장을 짓고 저장한다. read: 불러온 상태를 출력한다.
func _save_test(mode: String) -> void:
	player.force_active = true
	Combat.auto_spawn = false
	Save.autosave_enabled = false
	if mode == "write":
		player.teleport(Vector3(-6, 0.25, -5), 1.25)
		await _wait(0.4)   # 내 위치가 호스트에 알려진 뒤에 요청한다(거리 검사)
		build_line(World.DEV_LINE_ORIGINS[0])
		World.request_place(&"plot", Vector3i(3, 0, -6), 0)
		World.request("plant", [World.sim.occupancy.get(Vector3i(3, 0, -6), 0), "glowleaf_seed"])
		World.request_place(&"floor", Vector3i(-8, 0, -8), 0)
		World.request_place_free(&"lamp", Vector3(-6.5, 0.2, -6.5), 45)
		while World.sim.tick_count < 150:
			await get_tree().physics_frame
		await get_tree().process_frame   # 마지막 위치 보고가 나가도록
		await _wait(0.1)
		World.tick_enabled = false
		# 틱이 더 돌기 전에 같은 프레임에서 해시를 찍고 저장한다.
		print("SAVETEST write id=%s tick=%d hash=%s structures=%d" % [
			Save.world_id, World.sim.tick_count, World.sim.state_hash(), World.sim.structures.size()])
		var ok := Save.save_now(true)
		print("SAVETEST saved=%s" % ok)
		get_tree().quit(0 if ok else 1)
	else:
		await get_tree().process_frame
		var p := player.global_position
		print("SAVETEST read id=%s tick=%d hash=%s structures=%d pos=%.1f,%.1f yaw=%.2f ingots=%d" % [
			Save.world_id, World.sim.tick_count, World.sim.state_hash(), World.sim.structures.size(),
			p.x, p.z, player.yaw, World.my_count(&"iron_ingot")])
		get_tree().quit(0)


# ---------------------------------------------------------------------------
# 건축·제작·밭·탄약 자동 점검 (혼자, 화면 없이): `godot --headless -- --single --buildtest`
# ---------------------------------------------------------------------------

func _build_test() -> void:
	var errors: PackedStringArray = []
	player.force_active = true
	Combat.auto_spawn = false
	Save.autosave_enabled = false
	player.teleport(Vector3(6, 0.05, -6), 0.0)
	await _wait(0.4)
	var ingot := func() -> int: return World.my_count(&"iron_ingot")
	if ingot.call() != 40:
		errors.append("시작 주괴 %d (기대 40)" % ingot.call())
	build.set_active(true)

	# 바닥 → 벽 → 벽 위의 2층 바닥.
	_place_at(&"floor", Vector3(1, 0, -6))
	var floor1: int = World.sim.plates.get(Vector3i(0, 0, -8), 0)
	if floor1 == 0 or ingot.call() != 38:
		errors.append("바닥 설치 실패 (주괴 %d)" % ingot.call())
	_place_at(&"wall", Vector3(1, 0, -7.9))
	var wall_id: int = World.sim.walls.get(Vector4i(0, 0, -8, 0), 0)
	if wall_id == 0:
		errors.append("벽 설치 실패: %s" % build.reason)
	build.select(&"floor")
	build.update_target(Vector3(20, 4.0, -20), Vector3.UP, true)
	if build.reason != "no_support":
		errors.append("허공의 2층 바닥이 '%s' (기대 no_support)" % build.reason)
	_place_at(&"floor", Vector3(1, 4.0, -7))
	if not World.sim.plates.has(Vector3i(0, 4, -8)):
		errors.append("벽 위 2층 바닥 설치 실패: %s" % build.reason)

	# 설비 설치와 되돌리기: 비용이 빠졌다가 전액 돌아온다.
	var before: int = ingot.call()
	_place_at(&"smelter", Vector3(8.5, 0, -3.5))
	if ingot.call() != before - 10 or build.undo_count() != 4:
		errors.append("제련기 설치 후 주괴 %d, 되돌리기 %d개" % [ingot.call(), build.undo_count()])
	build.undo()
	if ingot.call() != before or World.sim.occupancy.has(Vector3i(7, 0, -5)):
		errors.append("되돌리기 후 주괴 %d (기대 %d)" % [ingot.call(), before])
	# 철거를 되돌리면 다시 선다.
	build.remove(wall_id)
	if World.sim.walls.has(Vector4i(0, 0, -8, 0)):
		errors.append("벽 철거 실패")
	build.undo()
	if not World.sim.walls.has(Vector4i(0, 0, -8, 0)) or ingot.call() != before:
		errors.append("철거 되돌리기 실패 (주괴 %d)" % ingot.call())

	# 벨트: 두 번 클릭해 ㄱ자로.
	build.select(&"belt")
	build.update_target(Vector3(6.5, 0, -1.5), Vector3.UP, true)
	build.confirm()
	build.update_target(Vector3(9.5, 0, -0.5), Vector3.UP, true)
	build.confirm()
	var belt: SimStructure = World.sim.structures.get(World.sim.occupancy.get(Vector3i(9, 0, -1), 0))
	if belt == null or belt.cells.size() != 5 or ingot.call() != before - 2:
		errors.append("벨트 설치 실패: %s (주괴 %d)" % [build.reason, ingot.call()])

	# 장식(자유 배치), 살 수 없는 것.
	_place_at(&"lamp", Vector3(5.2, 0, -2.6))
	if World.sim.decor_count != 1:
		errors.append("등불 설치 실패: %s" % build.reason)
	build.select(&"assembler")
	build.update_target(Vector3(20, 0, -3), Vector3.UP, true)
	if build.reason != "cannot_afford":
		errors.append("정밀 부품 없이 조립기가 '%s' (기대 cannot_afford)" % build.reason)

	# 작업대: 손 제작.
	_place_at(&"workbench", Vector3(4.5, 0, -10.5))
	var bench: int = World.sim.occupancy.get(Vector3i(3, 0, -12), 0)
	build.set_active(false)
	if not open_panel(bench):
		errors.append("작업대 패널이 열리지 않음")
	var ammo_before := World.my_count(&"rifle_ammo")
	before = ingot.call()
	panel.act("craft", ["make_rifle_ammo", 1])
	if World.my_count(&"rifle_ammo") != ammo_before + 30 or ingot.call() != before - 1:
		errors.append("탄약 제작 실패")
	_close_panel()

	# 밭: 심고, 물 주고, 수확.
	build.set_active(true)
	_place_at(&"plot", Vector3(8.5, 0, -8.5))
	build.set_active(false)
	var plot: SimStructure = World.sim.structures.get(World.sim.occupancy.get(Vector3i(7, 0, -9), 0))
	if plot == null:
		errors.append("밭 설치 실패: %s" % build.reason)
	else:
		open_panel(plot.id)
		panel.act("plant", [plot.id, "glowleaf_seed"])
		panel.act("water", [plot.id])
		if plot.crop < 0 or not plot.watered or World.my_count(&"glowleaf_seed") != 3:
			errors.append("심기/물 주기 실패")
		plot.growth = Registry.db.crops[plot.crop].grow_ticks - 3   # 2분을 기다리지 않는다
		await _wait(0.6)
		panel.act("harvest", [plot.id])
		if World.my_count(&"glowleaf") != 4 or World.sim.plot_state(plot) != "empty":
			errors.append("수확 실패 (빛잎 %d)" % World.my_count(&"glowleaf"))
		_close_panel()

	# 발전기와 제련기를 손으로 돌린다: 광석을 넣고 주괴를 꺼낸다.
	build.set_active(true)
	_place_at(&"bio_generator", Vector3(12.5, 0, -6.5))
	_place_at(&"smelter", Vector3(8.5, 0, -4.5))
	build.set_active(false)
	var gen: int = World.sim.occupancy.get(Vector3i(11, 0, -7), 0)
	var smelter: int = World.sim.occupancy.get(Vector3i(7, 0, -6), 0)
	if gen == 0 or smelter == 0:
		errors.append("발전기/제련기 설치 실패: %s (주괴 %d)" % [build.reason, ingot.call()])
	else:
		World.grant(1, {"biofuel": 1, "iron_ore": 4})
		open_panel(gen)
		panel.act("insert", [gen, "biofuel", 9999])
		_close_panel()
		open_panel(smelter)
		panel.act("insert", [smelter, "iron_ore", 9999])
		before = ingot.call()
		await _wait(9.0)
		panel.act("take", [smelter, "iron_ingot", 9999])
		_close_panel()
		if ingot.call() != before + 4 or World.my_count(&"iron_ore") != 0:
			errors.append("손 제련 실패: 주괴 %d → %d" % [before, ingot.call()])

	# 탄약: 재장전하면 소지품에서 빠진다. 탄약이 없으면 장전되지 않는다.
	player.equip_by_id(&"rifle")
	await _wait(0.4)
	ammo_before = World.my_count(&"rifle_ammo")
	player.gun.mag = 5
	player.try_reload()
	await _wait(player.gun.def.reload_time + 0.4)
	if player.gun.mag != 30 or World.my_count(&"rifle_ammo") != ammo_before - 25:
		errors.append("재장전: 탄창 %d, 소지 탄약 %d → %d" % [player.gun.mag, ammo_before, World.my_count(&"rifle_ammo")])
	World.request("consume", ["rifle_ammo", 1000])
	player._ammo_asks.clear()
	player.gun.mag = 0
	player.try_reload()
	await _wait(0.3)
	if player.gun.is_reloading() or player.gun.mag != 0:
		errors.append("탄약 없이 재장전됨")

	# 탭과 지붕, 포트 표시.
	build.select(&"roof")
	if build.selected().id != &"roof" or build.tab != 0:
		errors.append("지붕 선택 실패")
	build.next_tab()
	if build.selected().tab != &"industry":
		errors.append("탭 넘기기 실패: %s" % build.selected().tab)
	if StructureView.port_markers(Registry.db.structures[&"smelter"], Vector3i.ZERO, 0).size() != 2 \
			or StructureView.port_markers(Registry.db.structures[&"floor"], Vector3i.ZERO, 0).size() != 0:
		errors.append("포트 표시 개수가 다름")

	# 건축 구역: 구역 밖은 안 되고, 높은 단 위에서는 그 높이에 맞춰 놓인다.
	World.grant(1, {"iron_ingot": 20})
	build.set_active(true)
	build.select(&"storage")
	build.update_target(Vector3(46, 0, -20), Vector3.UP, true)
	if build.reason != "not_buildable":
		errors.append("구역 밖 설치가 '%s' (기대 not_buildable)" % build.reason)
	_place_at(&"storage", Vector3(60.5, 3.0, -25.5))
	if not World.sim.occupancy.has(Vector3i(59, 3, -27)):
		errors.append("높은 단 위 저장소 설치 실패: %s" % build.reason)
	_place_at(&"floor", Vector3(50, 3.0, -38))
	if not World.sim.plates.has(Vector3i(48, 3, -40)):
		errors.append("높은 단 위 바닥 설치 실패: %s" % build.reason)
	_place_at(&"wall", Vector3(50, 3.0, -39.9))
	_place_at(&"floor", Vector3(50, 7.0, -39))
	if not World.sim.plates.has(Vector3i(48, 7, -40)):
		errors.append("높은 단의 2층 바닥 설치 실패: %s" % build.reason)
	build.set_active(false)

	# 부하 시험 공장: 설비 504개가 서고, 돌아가고, 다시 눌러도 늘지 않는다.
	var built := World.dev_stress()
	if built != 504 or World.dev_stress() != 0:
		errors.append("부하 시험 공장 설비 %d개 (기대 504)" % built)
	var miners_before := 0
	for m in World.sim.crafters:
		miners_before += m.produced_total
	await _wait(3.0)
	var produced := -miners_before
	for m in World.sim.crafters:
		produced += m.produced_total
	if produced < 200:   # 채굴기 72대 × 초당 1개 × 3초
		errors.append("부하 시험 공장이 돌지 않음 (3초간 생산 %d)" % produced)

	# 너무 먼 설비는 쓸 수 없다.
	player.teleport(Vector3(60, 0.05, 60), 0.0)
	await _wait(0.3)
	_last_reject = ""
	World.request("take", [smelter, "iron_ingot", 1])
	if _last_reject != "too_far":
		errors.append("먼 설비 사용이 '%s' (기대 too_far)" % _last_reject)

	# 자동 저장과 같은 경로(스레드에서 쓰기)로 저장해 본다.
	var result: Array = []
	Save.saved.connect(func(ok: bool, _m: String) -> void: result.append(ok), CONNECT_ONE_SHOT)
	if not Save.save_now():
		errors.append("비동기 저장을 시작하지 못함")
	var waited := 0.0
	while result.is_empty() and waited < 10.0:
		await _wait(0.1)
		waited += 0.1
	if result != [true] or Save.store.read_manifest(Save.world_id).is_empty():
		errors.append("비동기 저장 실패 (%s)" % str(result))

	if errors.is_empty():
		print("BUILDTEST OK (구조물 %d)" % World.sim.structures.size())  # 9 + 높은 단의 4 + 부하 시험 공장
	else:
		for e in errors:
			print("BUILDTEST FAIL: %s" % e)
	get_tree().quit(0 if errors.is_empty() else 1)


## 건축 모드에서 그 종류를 골라, 조준점이 pos(윗면)인 것처럼 설치한다.
func _place_at(def_id: StringName, pos: Vector3) -> void:
	build.select(def_id)
	build.update_target(pos, Vector3.UP, true)
	build.confirm()


## 건축물이 있는 화면을 저장한다(렌더링 확인용).
func _build_shot(path: String) -> void:
	player.force_active = true
	Combat.auto_spawn = false
	player.teleport(Vector3(6, 0.05, 4), 0.0)
	await _wait(0.4)
	World.grant(1, {"iron_ingot": 200, "biofuel": 5})
	build.set_active(true)
	for x: float in [1.0, 5.0]:
		_place_at(&"floor", Vector3(x, 0, -6))
	_place_at(&"wall", Vector3(1, 0, -7.9))
	_place_at(&"wall", Vector3(5, 0, -7.9))
	build.rot = 1
	_place_at(&"wall", Vector3(0.1, 0, -6))
	build.rot = 0
	_place_at(&"floor", Vector3(1, 4.0, -7))
	_place_at(&"stairs", Vector3(9.5, 0, -6))
	_place_at(&"plot", Vector3(12.5, 0, -1.5))
	_place_at(&"workbench", Vector3(2.5, 0, -1.5))
	_place_at(&"lamp", Vector3(5.5, 0.2, -5.5))
	_place_at(&"table", Vector3(2.5, 0.2, -6))
	_place_at(&"smelter", Vector3(6, 0, -5))
	var plot: SimStructure = World.sim.structures.get(World.sim.occupancy.get(Vector3i(12, 0, -2), 0))
	if plot != null:
		World.request("plant", [plot.id, "glowleaf_seed"])
		plot.growth = 900
	_place_at(&"storage", Vector3(56.5, 3.0, -20.5))
	_place_at(&"floor", Vector3(62, 3.0, -30))
	build.select(&"assembler")
	if path.contains("terrace"):
		player.teleport(Vector3(36, 0.05, -14), -1.9)
	player.pitch = deg_to_rad(-12.0)
	await _wait(1.2)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
