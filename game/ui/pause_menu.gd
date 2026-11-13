class_name PauseMenu
extends Control
## Esc 메뉴. 멀티플레이에서는 세계가 멈추지 않으므로 "일시정지"가 아니라 메뉴일 뿐이다.

signal resumed
signal leave_requested

var in_world: bool = true        ## false면 저장·나가기 항목을 숨긴다(사격장)
var _buttons: VBoxContainer
var _settings: SettingsPanel
var _info: Label


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_buttons = VBoxContainer.new()
	_buttons.custom_minimum_size.x = 320
	_buttons.add_theme_constant_override(&"separation", 10)
	center.add_child(_buttons)
	_info = Label.new()
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_buttons.add_child(_info)
	_button("계속하기", close)
	_button("설정", func() -> void:
		_buttons.visible = false
		_settings.visible = true)
	if in_world:
		_button("저장 (호스트)", func() -> void:
			_info.text = "저장을 시작했습니다" if Save.save_now() else ("호스트만 저장할 수 있습니다" if not Net.is_host() else "이미 저장하는 중입니다"))
		_button("저장하고 시작 화면으로", func() -> void: leave_requested.emit())
	else:
		_button("시작 화면으로", func() -> void: leave_requested.emit())
	_button("게임 종료", func() -> void:
		if in_world:
			Net.leave()
		get_tree().quit())
	_settings = SettingsPanel.new()
	_settings.visible = false
	add_child(_settings)
	_settings.closed.connect(func() -> void: _buttons.visible = true)


func open() -> void:
	visible = true
	_buttons.visible = true
	_settings.visible = false
	_info.text = ""
	if in_world:
		_info.text = "%s · 난이도 %s" % [Save.world_name, World.difficulty_name()]
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close() -> void:
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	resumed.emit()


func _button(text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	_buttons.add_child(b)
