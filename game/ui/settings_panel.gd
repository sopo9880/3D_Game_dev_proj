class_name SettingsPanel
extends PanelContainer
## 설정 화면: 감도, 시야각, 음량, 화면, 키 배치. 시작 화면과 일시정지 메뉴가 함께 쓴다.

signal closed

var _waiting_action: StringName = &""
var _key_buttons: Dictionary[StringName, Button] = {}


func _ready() -> void:
	custom_minimum_size = Vector2(520, 0)
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	add_child(box)
	var title := Label.new()
	title.text = "설정"
	title.add_theme_font_size_override(&"font_size", 24)
	box.add_child(title)
	_slider(box, "마우스 감도", "sens", 0.1, 5.0, 0.05)
	_slider(box, "시야각", "fov", 60.0, 120.0, 1.0)
	_slider(box, "음량", "volume", 0.0, 1.0, 0.05)
	_check(box, "전체 화면", "fullscreen")
	_check(box, "수직 동기화", "vsync")
	var keys_title := Label.new()
	keys_title.text = "키 배치 (버튼을 누른 뒤 새 키를 누르세요)"
	keys_title.add_theme_color_override(&"font_color", Color(0.6, 0.9, 0.7))
	box.add_child(keys_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 260
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for action: StringName in SettingsStore.REBINDABLE:
		var name_label := Label.new()
		name_label.text = SettingsStore.REBINDABLE[action]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(name_label)
		var b := Button.new()
		b.custom_minimum_size.x = 160
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(func() -> void:
			_waiting_action = action
			_refresh_keys())
		grid.add_child(b)
		_key_buttons[action] = b
	var row := HBoxContainer.new()
	box.add_child(row)
	var reset := Button.new()
	reset.text = "키 배치 기본값으로"
	reset.pressed.connect(func() -> void:
		Settings.reset_keys()
		_refresh_keys())
	row.add_child(reset)
	var done := Button.new()
	done.text = "닫기"
	done.pressed.connect(func() -> void:
		_waiting_action = &""
		visible = false
		closed.emit())
	row.add_child(done)
	_refresh_keys()


func _input(event: InputEvent) -> void:
	if not visible or _waiting_action == &"" or not event is InputEventKey or not event.pressed:
		return
	var key := (event as InputEventKey).physical_keycode
	get_viewport().set_input_as_handled()
	if key != KEY_ESCAPE:
		Settings.rebind(_waiting_action, key)
	_waiting_action = &""
	_refresh_keys()


func _refresh_keys() -> void:
	for action: StringName in _key_buttons:
		var b := _key_buttons[action]
		b.text = "키를 누르세요…" if action == _waiting_action else OS.get_keycode_string(Settings.store.key_of(action))


func _slider(parent: Control, text: String, key: String, lo: float, hi: float, step: float) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 130
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var v := Label.new()
	v.custom_minimum_size.x = 56
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.text = "%.2f" % s.value if step < 1.0 else str(roundi(s.value))
	row.add_child(v)
	s.value_changed.connect(func(value: float) -> void:
		Settings.set_value(key, value)
		v.text = "%.2f" % value if step < 1.0 else str(roundi(value)))


func _check(parent: Control, text: String, key: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = bool(Settings.get_value(key))
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(on: bool) -> void: Settings.set_value(key, on))
	parent.add_child(c)
