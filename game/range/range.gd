extends Node3D
## 사격 감각 테스트용 사격장. 맵은 전부 코드로 만든 임시 상자다.
## 실행 인자 `-- --selftest` 를 주면 자동 점검만 하고 끝낸다(CI용).

const GRID_SHADER := preload("res://game/range/grid.gdshader")
const CHALLENGE_COUNT := 15

var player: PlayerController
var hud: Hud
var panel: TuningPanel
var sfx: Sfx
var fx: Fx

var _targets: Array[RangeTarget] = []
var _challenge_left: int = 0
var _challenge_start: float = 0.0
var _challenge_shots: int = 0
var _challenge_hits: int = 0
var _challenge_target: RangeTarget
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	InputSetup.register()
	_build_environment()
	_build_level()

	sfx = Sfx.new()
	add_child(sfx)
	fx = Fx.new()
	add_child(fx)
	player = PlayerController.new()
	player.sfx = sfx
	player.fx = fx
	add_child(player)
	player.teleport(Vector3(0, 0.05, 0), 0.0)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	hud.player = player
	layer.add_child(hud)
	panel = TuningPanel.new()
	panel.player = player
	layer.add_child(panel)
	player.hit_confirmed.connect(hud.on_hit)
	player.weapon_switched.connect(func(_g: Gun) -> void:
		if panel.visible:
			panel.rebuild())

	for arg in OS.get_cmdline_user_args():
		if arg == "--selftest":
			_selftest()
		elif arg.begins_with("--screenshot="):
			_screenshot(arg.trim_prefix("--screenshot="))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_tuning"):
		panel.visible = not panel.visible
		player.input_enabled = not panel.visible
		if panel.visible:
			panel.rebuild()
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed(&"pause"):
		if panel.visible:
			panel.visible = false
			player.input_enabled = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"toggle_profile"):
		player.apply_profile(player.profile_index + 1)
		player.reset_stats()
		if panel.visible:
			panel.rebuild()
	elif event.is_action_pressed(&"toggle_help"):
		hud.toggle_help()
	elif event.is_action_pressed(&"reset_stats"):
		player.reset_stats()
		for t in _targets:
			t.reset()
	elif event.is_action_pressed(&"start_challenge"):
		_start_challenge()
	elif event.is_action_pressed(&"sens_up"):
		player.sens_mult = minf(player.sens_mult + 0.05, 5.0)
	elif event.is_action_pressed(&"sens_down"):
		player.sens_mult = maxf(player.sens_mult - 0.05, 0.1)
	elif event.is_action_pressed(&"toggle_fullscreen"):
		var full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if full else DisplayServer.WINDOW_MODE_FULLSCREEN)


func _process(_delta: float) -> void:
	if _challenge_left > 0:
		hud.message = "표적 도전  남은 표적 %d  ·  %.1f초" % [_challenge_left, _now() - _challenge_start]
	# 맵 밖으로 떨어지면 시작 지점으로.
	if player.global_position.y < -20.0:
		player.teleport(Vector3(0, 0.05, 0), 0.0)


# ---------------------------------------------------------------------------
# 표적 도전: 무작위 위치에 하나씩 나오는 표적 15개를 얼마나 빨리 쓰러뜨리나.
# ---------------------------------------------------------------------------

func _start_challenge() -> void:
	if _challenge_target != null:
		_challenge_target.queue_free()
	_rng.randomize()
	_challenge_left = CHALLENGE_COUNT
	_challenge_start = _now()
	_challenge_shots = player.stat_shots
	_challenge_hits = player.stat_hits
	_spawn_challenge_target()


func _spawn_challenge_target() -> void:
	var t := RangeTarget.new()
	t.respawn_time = 0.0
	t.position = Vector3(_rng.randf_range(-9.0, 9.0), 0.0, _rng.randf_range(-12.0, -40.0))
	if _rng.randf() < 0.4:
		t.move_axis = Vector3.RIGHT
		t.move_range = _rng.randf_range(1.5, 3.5)
		t.move_speed = _rng.randf_range(2.0, 5.0)
	t.died.connect(_on_challenge_kill)
	add_child(t)
	_challenge_target = t


func _on_challenge_kill(t: RangeTarget) -> void:
	t.queue_free()
	_challenge_target = null
	_challenge_left -= 1
	if _challenge_left > 0:
		_spawn_challenge_target()
		return
	var shots := player.stat_shots - _challenge_shots
	var hits := player.stat_hits - _challenge_hits
	hud.message = "도전 완료  %.2f초  ·  명중률 %.0f%%  (%s)   T로 다시" % [
		_now() - _challenge_start, 100.0 * hits / maxi(shots, 1), player.gun.def.display_name]


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# ---------------------------------------------------------------------------
# 맵
# ---------------------------------------------------------------------------

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
	env.glow_enabled = true
	env.glow_intensity = 0.4
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)


func _build_level() -> void:
	var ground := Color(0.34, 0.42, 0.36)
	var wall := Color(0.45, 0.45, 0.5)
	var block := Color(0.55, 0.48, 0.38)
	_box(Vector3(0, -0.5, -20), Vector3(160, 1, 160), ground)
	# 뒷벽과 옆벽
	_box(Vector3(0, 4, -72), Vector3(60, 8, 1), wall)
	_box(Vector3(-14, 2, -36), Vector3(1, 4, 72), wall)
	_box(Vector3(12, 2, -36), Vector3(1, 4, 72), wall)
	# 사대
	_box(Vector3(0, 0.5, -3), Vector3(8, 1, 0.4), block)

	# 고정 표적: 10 / 20 / 35 / 50m
	for spec: Array in [[-2.0, 10.0], [2.0, 20.0], [-3.0, 35.0], [3.0, 50.0]]:
		_target(Vector3(spec[0], 0, -spec[1]))
		_sign(Vector3(spec[0] + 1.2, 0.0, -spec[1]), "%dm" % int(spec[1]))
	# 움직이는 표적
	_target(Vector3(0, 0, -15), 5.0, 3.0)
	_target(Vector3(0, 0, -30), 7.0, 5.0)
	# DPS 허수아비
	var dummy := _target(Vector3(6, 0, -8))
	dummy.invulnerable = true
	_sign(Vector3(7.2, 0, -8), "DPS")

	# 이동 연습 구역 (오른쪽)
	_sign(Vector3(20, 0, -4), "이동 연습")
	_box(Vector3(20, 0.25, -10), Vector3(3, 0.5, 3), block)
	_box(Vector3(24, 0.5, -10), Vector3(3, 1.0, 3), block)
	_box(Vector3(28, 0.75, -10), Vector3(3, 1.5, 3), block)
	_box(Vector3(34, 0.75, -10), Vector3(3, 1.5, 3), block)       # 3m 건너뛰기
	_box(Vector3(24, 1.0, -18), Vector3(10, 0.3, 4), block, Vector3(0, 0, 11.3))  # 경사로
	_box(Vector3(31, 2.0, -18), Vector3(4, 0.3, 4), block)
	# 슬라이딩으로 지나가는 낮은 문 (틈 1.3m)
	_box(Vector3(22, 2.15, -28), Vector3(14, 1.7, 0.5), wall)
	_box(Vector3(14.5, 1.5, -28), Vector3(1, 3, 0.5), wall)
	_box(Vector3(29.5, 1.5, -28), Vector3(1, 3, 0.5), wall)
	_sign(Vector3(22, 0, -24), "달리다 앉기 = 슬라이딩")
	# 엄폐물
	_box(Vector3(-6, 0.6, -6), Vector3(2.5, 1.2, 0.5), block)
	_box(Vector3(-9, 1.0, -12), Vector3(0.5, 2.0, 3), block)


func _target(pos: Vector3, move_range: float = 0.0, move_speed: float = 0.0) -> RangeTarget:
	var t := RangeTarget.new()
	t.position = pos
	t.move_axis = Vector3.RIGHT
	t.move_range = move_range
	t.move_speed = move_speed
	add_child(t)
	_targets.append(t)
	return t


func _sign(pos: Vector3, text: String) -> void:
	var l := Label3D.new()
	l.text = text
	l.position = pos + Vector3(0, 0.5, 0)
	l.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	l.pixel_size = 0.006
	l.font_size = 48
	l.outline_size = 12
	add_child(l)


func _box(pos: Vector3, size: Vector3, color: Color, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
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
	mat.set_shader_parameter(&"base_color", color)
	mat.set_shader_parameter(&"line_color", color.darkened(0.3))
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	return body


# ---------------------------------------------------------------------------
# 자동 점검: 화면 없이도 이동과 사격의 기본 동작을 확인한다.
# ---------------------------------------------------------------------------

func _selftest() -> void:
	var errors: PackedStringArray = []
	player.force_active = true
	await _frames(20)
	if not player.is_on_floor():
		errors.append("시작 후 바닥에 서 있지 않음 (y=%.2f)" % player.global_position.y)

	# 무기마다 10m 표적의 몸통과 머리를 쏜다.
	var target := _targets[0]
	for g in player.guns:
		player.equip_by_id(g.def.id)
		await _frames(20)
		target.reset()
		g.def.spread_hip = 0.0
		g.def.spread_move = 0.0
		g.bloom = 0.0
		_aim_at(target.global_position + Vector3(0, 0.975, 0))
		await _frames(2)
		var mag_before := g.mag
		player._shoot()
		if g.mag != mag_before - 1:
			errors.append("%s: 탄약이 줄지 않음" % g.def.id)
		var body_damage := target.max_hp - target.hp
		if body_damage <= 0.0:
			errors.append("%s: 몸통 사격이 피해를 주지 않음" % g.def.id)
		if g.def.pellets == 1:
			target.reset()
			await _frames(2)
			g.cooldown = 0.0
			_aim_at(target.global_position + Vector3(0, 1.69, 0))
			await _frames(2)
			player._shoot()
			var head_damage := target.max_hp - target.hp
			if not is_equal_approx(head_damage, body_damage * g.def.head_mult):
				errors.append("%s: 머리 피해 %.2f, 기대 %.2f" % [g.def.id, head_damage, body_damage * g.def.head_mult])
		# 탄창을 비우고 재장전한다.
		while g.mag > 0:
			g.cooldown = 0.0
			player._shoot()
		if g.can_fire():
			errors.append("%s: 빈 탄창으로 쏠 수 있음" % g.def.id)
		g.start_reload()
		await get_tree().create_timer(g.def.reload_time * (g.def.mag if g.def.reload_per_shell else 1) + 0.3).timeout
		if g.mag != g.def.mag:
			errors.append("%s: 재장전 후 탄창 %d / %d" % [g.def.id, g.mag, g.def.mag])

	# 연사 속도: 소총을 1초 동안 쏘면 10발 안팎.
	player.equip_by_id(&"rifle")
	await _frames(20)
	var rifle := player.gun
	rifle.mag = rifle.def.mag
	var shots_before := player.stat_shots
	Input.action_press(&"fire")
	await get_tree().create_timer(1.0).timeout
	Input.action_release(&"fire")
	var fired := player.stat_shots - shots_before
	if fired < 9 or fired > 11:
		errors.append("소총 1초 연사 %d발 (기대 10발 안팎)" % fired)

	# 이동: 앞으로 1초 걷기, 점프.
	player.pitch = 0.0
	player.yaw = PI  # 사대 반대쪽(+Z)으로
	var start := player.global_position
	Input.action_press(&"move_forward")
	await get_tree().create_timer(1.0).timeout
	Input.action_release(&"move_forward")
	var walked := player.global_position.distance_to(start)
	if walked < 4.0 or walked > 5.5:
		errors.append("1초 걷기 %.2fm (기대 약 %.1fm)" % [walked, player.walk_speed])
	await _frames(20)
	var y0 := player.global_position.y
	Input.action_press(&"jump")
	player._jump_buffer = 0.12
	await _frames(12)
	Input.action_release(&"jump")
	if player.global_position.y - y0 < 0.5:
		errors.append("점프 높이 %.2fm" % (player.global_position.y - y0))

	# 전술 아레나 규칙: 달리기와 슬라이딩이 없고, 움직이면 탄이 크게 퍼지며, 소총 머리 한 발에 쓰러진다.
	await _frames(20)
	player.apply_profile(1)
	await _frames(20)
	if player.allow_sprint or player.allow_slide or player.guns.size() != 3:
		errors.append("아레나 규칙이 적용되지 않음")
	player.equip_by_id(&"rifle")
	await _frames(20)
	var still := player.gun.spread(false, 0.0, false)
	var moving := player.gun.spread(false, 1.0, false)
	if still > 0.5 or moving < still * 8.0:
		errors.append("아레나 소총 탄퍼짐: 정지 %.2f, 이동 %.2f" % [still, moving])
	target.reset()
	await _frames(2)
	_aim_at(target.global_position + Vector3(0, 1.69, 0))
	await _frames(2)
	player._shoot()
	await _frames(2)
	if target.visible:
		errors.append("아레나 소총 머리 한 발에 쓰러지지 않음 (남은 체력 %.0f)" % target.hp)
	start = player.global_position
	Input.action_press(&"sprint")
	Input.action_press(&"move_forward")
	await get_tree().create_timer(1.0).timeout
	Input.action_release(&"move_forward")
	Input.action_release(&"sprint")
	walked = player.global_position.distance_to(start)
	if walked > 3.2:
		errors.append("아레나에서 Shift는 조용히 걷기여야 함: 1초에 %.2fm" % walked)
	player.apply_profile(0)
	await _frames(5)

	# 조정값 내보내기 형식.
	var exported := panel.export_data()
	if (exported["weapons"] as Array).size() != player.guns.size():
		errors.append("조정값 내보내기에 무기가 빠짐")

	if errors.is_empty():
		print("SELFTEST OK")
	else:
		for e in errors:
			print("SELFTEST FAIL: %s" % e)
	get_tree().quit(0 if errors.is_empty() else 1)


func _aim_at(point: Vector3) -> void:
	var eye := player.camera.global_position
	var d := point - eye
	player.yaw = atan2(-d.x, -d.z)
	player.pitch = atan2(d.y, Vector2(d.x, d.z).length())
	player._recoil = Vector2.ZERO
	player._recoil_target = Vector2.ZERO
	player._shake = 0.0


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
	await get_tree().process_frame


## 몇 프레임 뒤 화면을 PNG로 저장하고 끝낸다(렌더링 확인용).
func _screenshot(path: String) -> void:
	player.force_active = true
	_aim_at(_targets[0].global_position + Vector3(1.5, 1.2, 0))
	await _frames(40)
	if path.contains("panel"):
		panel.visible = true
		panel.rebuild()
	player.gun.def.shake = 0.0
	player._shoot()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
