class_name TuningPanel
extends PanelContainer
## F1 수치 조정 패널. 무기와 이동 수치를 실행 중에 바꾸고 JSON으로 내보낸다.
## 테스터가 "이 값이 더 낫다"를 숫자로 돌려줄 수 있게 하는 것이 목적이다.

var player: PlayerController
var _box: VBoxContainer
var _status: Label


func _ready() -> void:
	custom_minimum_size.x = 430
	set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	offset_left = -446.0
	offset_right = -16.0
	offset_top = 16.0
	offset_bottom = -16.0
	visible = false
	var outer := VBoxContainer.new()
	add_child(outer)
	var title := Label.new()
	title.text = "수치 조정 (F1로 닫기)"
	title.add_theme_font_size_override(&"font_size", 20)
	outer.add_child(title)
	var buttons := HBoxContainer.new()
	outer.add_child(buttons)
	var copy := Button.new()
	copy.text = "JSON 복사 + 파일 저장"
	copy.pressed.connect(_export)
	buttons.add_child(copy)
	var reset := Button.new()
	reset.text = "기본값으로"
	reset.pressed.connect(_reset)
	buttons.add_child(reset)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override(&"font_size", 13)
	outer.add_child(_status)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)
	_box = VBoxContainer.new()
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_box)


func rebuild() -> void:
	for c in _box.get_children():
		c.queue_free()
	_section("무기: %s" % player.gun.def.display_name)
	for t in WeaponDef.TUNABLES:
		_row(player.gun.def, t)
	_section("이동과 시점")
	for t in PlayerController.TUNABLES:
		_row(player, t)


func _section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", 17)
	l.add_theme_color_override(&"font_color", Color(0.6, 0.9, 0.7))
	_box.add_child(l)


func _row(target: Object, t: Array) -> void:
	var prop: String = t[0]
	var row := HBoxContainer.new()
	_box.add_child(row)
	var name_label := Label.new()
	name_label.text = t[4]
	name_label.custom_minimum_size.x = 150
	name_label.add_theme_font_size_override(&"font_size", 14)
	row.add_child(name_label)
	var slider := HSlider.new()
	slider.min_value = t[1]
	slider.max_value = t[2]
	slider.step = t[3]
	slider.value = float(target.get(prop))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.focus_mode = Control.FOCUS_NONE
	row.add_child(slider)
	var value_label := Label.new()
	value_label.custom_minimum_size.x = 56
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_font_size_override(&"font_size", 14)
	value_label.text = _fmt(slider.value, t[3])
	row.add_child(value_label)
	slider.value_changed.connect(func(v: float) -> void:
		if target.get(prop) is int:
			target.set(prop, roundi(v))
		else:
			target.set(prop, v)
		value_label.text = _fmt(v, t[3]))


func _fmt(v: float, step: float) -> String:
	return str(roundi(v)) if step >= 1.0 else ("%.2f" % v if step < 0.1 else "%.1f" % v)


func export_data() -> Dictionary:
	var weapons: Array = []
	for g in player.guns:
		weapons.append(g.def.to_dict())
	var movement := {}
	for t in PlayerController.TUNABLES:
		movement[t[0]] = snappedf(float(player.get(t[0])), 0.001)
	return {"version": ProjectSettings.get_setting("application/config/version", "?"), "weapons": weapons, "movement": movement}


func _export() -> void:
	var text := JSON.stringify(export_data(), "  ")
	DisplayServer.clipboard_set(text)
	var path := "user://tuning_export.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	_status.text = "클립보드에 복사했습니다. 파일: %s" % ProjectSettings.globalize_path(path)


func _reset() -> void:
	var defaults := WeaponDef.load_all("res://data/weapons.json")
	for g in player.guns:
		for d in defaults:
			if d.id == g.def.id:
				g.def = d
	var fresh := PlayerController.new()
	for t in PlayerController.TUNABLES:
		player.set(t[0], fresh.get(t[0]))
	fresh.free()
	rebuild()
	_status.text = "기본값으로 되돌렸습니다."
