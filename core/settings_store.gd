class_name SettingsStore
extends RefCounted
## 플레이어 설정(감도, 시야각, 음량, 화면, 키 배치)을 읽고 쓴다. 월드와 무관하게 이 PC에 저장된다.

const DEFAULTS: Dictionary = {
	"name": "Player", "sens": 1.0, "fov": 90.0, "volume": 0.8,
	"fullscreen": false, "vsync": true, "keys": {},
}
const LIMITS: Dictionary = {"sens": [0.1, 5.0], "fov": [60.0, 120.0], "volume": [0.0, 1.0]}
## 바꿀 수 있는 키: 액션 → 표시 이름.
const REBINDABLE: Dictionary[StringName, String] = {
	&"move_forward": "앞으로", &"move_back": "뒤로", &"move_left": "왼쪽", &"move_right": "오른쪽",
	&"jump": "점프", &"sprint": "달리기", &"crouch": "앉기 / 슬라이딩",
	&"reload": "재장전 / 건축 회전", &"melee": "근접 공격", &"throw": "투척", &"interact": "상호작용",
	&"build_toggle": "건축 모드", &"build_tab": "건축 탭", &"build_pick": "같은 것 고르기", &"build_undo": "되돌리기",
}

var path: String
var data: Dictionary = {}


func _init(file_path: String = "user://settings.json") -> void:
	path = file_path
	data = DEFAULTS.duplicate(true)


## 파일에서 읽는다. 없거나 깨졌으면 기본값을 쓴다. 범위를 벗어난 값은 고친다.
func load_file() -> void:
	data = DEFAULTS.duplicate(true)
	if not FileAccess.file_exists(path):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return   # 깨진 파일: 기본값으로 시작한다
	var parsed: Dictionary = json.data
	for key: String in DEFAULTS:
		var v: Variant = parsed.get(key)
		if v == null:
			continue
		match typeof(DEFAULTS[key]):
			TYPE_FLOAT:
				if v is float or v is int:
					data[key] = clampf(float(v), LIMITS[key][0], LIMITS[key][1])
			TYPE_BOOL:
				if v is bool:
					data[key] = v
			TYPE_STRING:
				if v is String and (v as String).strip_edges() != "":
					data[key] = (v as String).strip_edges().left(24)
			TYPE_DICTIONARY:
				if v is Dictionary:
					for action: String in v:
						if REBINDABLE.has(StringName(action)) and (v[action] is float or v[action] is int):
							(data["keys"] as Dictionary)[action] = int(v[action])


func save_file() -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true


func set_value(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key) or key == "keys":
		return
	if LIMITS.has(key):
		value = clampf(float(value), LIMITS[key][0], LIMITS[key][1])
	data[key] = value


## 액션의 키를 바꾼다. 같은 키를 쓰던 다른 액션은 원래 이 액션이 쓰던 키를 넘겨받는다(겹치지 않게).
func rebind(action: StringName, keycode: int) -> void:
	if not REBINDABLE.has(action) or keycode <= 0:
		return
	var old := key_of(action)
	for other: StringName in REBINDABLE:
		if other != action and key_of(other) == keycode:
			(data["keys"] as Dictionary)[String(other)] = old
	(data["keys"] as Dictionary)[String(action)] = keycode


## 그 액션에 지금 배정된 키(설정 → 없으면 기본 배치).
func key_of(action: StringName) -> int:
	var custom: Variant = (data["keys"] as Dictionary).get(String(action))
	if custom != null:
		return int(custom)
	var defaults: Array = InputSetup.KEYS.get(action, [])
	return int(defaults[0]) if not defaults.is_empty() else 0


func reset_keys() -> void:
	data["keys"] = {}


## 키 배치를 InputMap에 적용한다. 바꾼 액션은 그 키 하나만 갖고, 나머지는 기본 배치를 유지한다.
func apply_keys() -> void:
	InputSetup.register()
	for action: StringName in REBINDABLE:
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		var keys: Array = InputSetup.KEYS.get(action, [])
		if (data["keys"] as Dictionary).has(String(action)):
			keys = [key_of(action)]
		for k: Variant in keys:
			var ev := InputEventKey.new()
			ev.physical_keycode = int(k) as Key
			InputMap.action_add_event(action, ev)
