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
	add_child(player)
	# 접속한 순서대로 조금씩 떨어진 자리에서 시작한다.
	player.teleport(Vector3(float(Net.players.size() - 1) * 1.5, 0.05, 0), 0.0)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.player = player
	hud.help_lines = [
		"WASD 이동 · Shift 달리기 · Space 점프 (턱 앞에서 앞으로 밀면 올라타기) · Ctrl 앉기/슬라이딩",
		"좌클릭 사격 · 우클릭 조준 · R 재장전 · 1/2/3 무기 · G 수류탄 · E 동료 일으키기",
		"벽 옆에서 달리며 점프 = 벽 달리기, 다시 점프 = 벽 차기 · 뒤쪽(+Z) 담장 안이 전투 구역",
		"B 저장소 설치 · N 기준 생산 라인 건설 · X 조준한 구조물 철거 · Esc 마우스 풀기",
	]
	layer.add_child(hud)
	player.hit_confirmed.connect(hud.on_hit)

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
	if Combat.inventory.is_empty():
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
