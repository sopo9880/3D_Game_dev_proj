class_name InputSetup
extends RefCounted
## 입력 액션을 코드로 등록한다. 키 설정 화면이 생기면 여기의 기본값 위에 덮어쓴다.

const KEYS: Dictionary[StringName, Array] = {
	&"move_forward": [KEY_W], &"move_back": [KEY_S], &"move_left": [KEY_A], &"move_right": [KEY_D],
	&"jump": [KEY_SPACE], &"sprint": [KEY_SHIFT], &"crouch": [KEY_CTRL, KEY_C],
	&"reload": [KEY_R],
	&"weapon_1": [KEY_1], &"weapon_2": [KEY_2], &"weapon_3": [KEY_3],
	&"toggle_tuning": [KEY_F1], &"toggle_profile": [KEY_F2], &"toggle_help": [KEY_H], &"reset_stats": [KEY_F5],
	&"start_challenge": [KEY_T], &"sens_down": [KEY_BRACKETLEFT], &"sens_up": [KEY_BRACKETRIGHT],
	&"toggle_fullscreen": [KEY_F11], &"pause": [KEY_ESCAPE],
	&"throw": [KEY_G], &"interact": [KEY_E],
	&"dev_build_box": [KEY_B], &"dev_build_line": [KEY_N], &"dev_remove": [KEY_X],
}
const MOUSE: Dictionary[StringName, int] = {
	&"fire": MOUSE_BUTTON_LEFT, &"aim": MOUSE_BUTTON_RIGHT,
	&"weapon_next": MOUSE_BUTTON_WHEEL_DOWN, &"weapon_prev": MOUSE_BUTTON_WHEEL_UP,
}


static func register() -> void:
	for action: StringName in KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key: Key in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	for action: StringName in MOUSE:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE[action] as MouseButton
		InputMap.action_add_event(action, ev)
