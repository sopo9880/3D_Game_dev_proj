extends Control
## 시작 화면. 실행 인자가 있으면 메뉴를 건너뛴다.
##   -- --single                 혼자 샌드박스
##   -- --host [--port=N]        호스트
##   --world=ID                  저장된 월드 이어 하기(없으면 새 월드)   --saveroot=경로  세이브 폴더
##   -- --join=주소 [--port=N]   참가
##   -- --range / --selftest / --screenshot=경로   사격장
##   --name=이름

const RANGE_SCENE := "res://game/range/range.tscn"
const SANDBOX_SCENE := "res://game/world/sandbox.tscn"

var _status: Label
var _address: LineEdit
var _name: LineEdit
var _worlds: OptionButton
var _world_ids: Array[String] = []
var _difficulty: OptionButton
var _settings: SettingsPanel


func _ready() -> void:
	InputSetup.register()
	Net.local_name = str(Settings.get_value("name"))
	Net.connected.connect(_enter_world)
	Net.disconnected.connect(_on_disconnected)
	var port := Net.DEFAULT_PORT
	var mode := ""
	var address := ""
	var world_id := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.trim_prefix("--port="))
		elif arg.begins_with("--difficulty="):
			Net.new_world_difficulty = arg.trim_prefix("--difficulty=")
		elif arg.begins_with("--world="):
			world_id = arg.trim_prefix("--world=")
		elif arg.begins_with("--saveroot="):
			Save.set_root(arg.trim_prefix("--saveroot="))
		elif arg == "--savetest=read":
			World.tick_enabled = false   # 불러온 직후의 상태를 그대로 비교한다
		elif arg.begins_with("--name="):
			Net.local_name = arg.trim_prefix("--name=")
		elif arg.begins_with("--join="):
			mode = "join"
			address = arg.trim_prefix("--join=")
		elif arg in ["--single", "--host"]:
			mode = arg.trim_prefix("--")
		elif arg in ["--range", "--selftest"] or arg.begins_with("--screenshot="):
			mode = "range"
	_build_menu()
	match mode:
		"range": get_tree().change_scene_to_file.call_deferred(RANGE_SCENE)
		"single": Net.start_single.call_deferred(world_id)
		"host": _host.call_deferred(port, world_id)
		"join": _join.call_deferred(address, port)


func _build_menu() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.13, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = 360
	box.add_theme_constant_override(&"separation", 10)
	center.add_child(box)
	var title := Label.new()
	title.text = "Edenfall"
	title.add_theme_font_size_override(&"font_size", 48)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var ver := Label.new()
	ver.text = "v%s · 개발용 샌드박스" % Net.version()
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ver.modulate.a = 0.6
	box.add_child(ver)
	_name = LineEdit.new()
	_name.placeholder_text = "이름"
	_name.text = Net.local_name
	box.add_child(_name)
	_worlds = OptionButton.new()
	_worlds.add_item("새 월드")
	for m in Save.store.list_worlds():
		var when := Time.get_datetime_string_from_unix_time(int(m["saved_at"]), true)
		_worlds.add_item("%s  ·  %s  ·  %d분 플레이" % [m["name"], when, int(m["play_ticks"]) / 600])
		_world_ids.append(str(m["world_id"]))
	if _world_ids.size() > 0:
		_worlds.select(1)   # 가장 최근 월드를 기본으로
	box.add_child(_worlds)
	_difficulty = OptionButton.new()
	for d in World.DIFFICULTIES:
		_difficulty.add_item("새 월드 난이도: %s" % World.DIFFICULTY_NAMES[d])
	_difficulty.select(1)
	box.add_child(_difficulty)
	_button(box, "혼자 시작", func() -> void:
		_take_name()
		Net.start_single(_selected_world()))
	_button(box, "호스트 (친구가 접속할 수 있게 열기)", func() -> void:
		_take_name()
		_host(Net.DEFAULT_PORT, _selected_world()))
	_address = LineEdit.new()
	_address.placeholder_text = "호스트 주소 (예: 192.168.0.10)"
	_address.text = "127.0.0.1"
	box.add_child(_address)
	_button(box, "참가", func() -> void:
		_take_name()
		_join(_address.text.strip_edges(), Net.DEFAULT_PORT))
	_button(box, "사격장", func() -> void: get_tree().change_scene_to_file(RANGE_SCENE))
	_button(box, "설정", func() -> void: _settings.visible = true)
	_button(box, "종료", func() -> void: get_tree().quit())
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_settings = SettingsPanel.new()
	_settings.visible = false
	add_child(_settings)


func _button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)


func _take_name() -> void:
	Net.new_world_difficulty = World.DIFFICULTIES[_difficulty.selected]
	if _name.text.strip_edges() != "":
		Net.local_name = _name.text.strip_edges()
		if Net.local_name != str(Settings.get_value("name")):
			Settings.set_value("name", Net.local_name)


func _selected_world() -> String:
	var i := _worlds.selected - 1
	return _world_ids[i] if i >= 0 and i < _world_ids.size() else ""


func _host(port: int, world_id: String = "") -> void:
	var err := Net.host(port, world_id)
	if err != OK:
		_status.text = "호스트를 열 수 없습니다 (포트 %d, 오류 %d)" % [port, err]
		print("HOST FAILED %d" % err)


func _join(address: String, port: int) -> void:
	var err := Net.join(address, port)
	_status.text = "%s:%d 에 접속 중…" % [address, port] if err == OK else "접속을 시작할 수 없습니다 (오류 %d)" % err


func _enter_world() -> void:
	get_tree().change_scene_to_file(SANDBOX_SCENE)


func _on_disconnected(reason: String) -> void:
	if is_inside_tree() and _status != null:
		_status.text = "연결이 끊겼습니다: %s" % reason
