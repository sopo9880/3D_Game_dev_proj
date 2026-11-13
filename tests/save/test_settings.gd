extends TestCase

const PATH := "user://test_settings.json"

var store: SettingsStore


func before_each() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(PATH)
	store = SettingsStore.new(PATH)


func test_defaults_without_file() -> void:
	store.load_file()
	eq(store.data["sens"], 1.0, "감도")
	eq(store.data["fov"], 90.0, "시야각")
	eq(store.key_of(&"jump"), KEY_SPACE, "기본 점프 키")


func test_values_round_trip_and_are_clamped() -> void:
	store.set_value("sens", 2.5)
	store.set_value("fov", 500.0)
	store.set_value("fullscreen", true)
	store.set_value("nope", 1)
	check(store.save_file(), "저장")
	var other := SettingsStore.new(PATH)
	other.load_file()
	eq(other.data["sens"], 2.5, "감도")
	eq(other.data["fov"], 120.0, "시야각은 한도까지")
	eq(other.data["fullscreen"], true, "전체 화면")
	check(not other.data.has("nope"), "모르는 항목은 받지 않는다")


func test_corrupt_or_hostile_file_falls_back() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string('{"sens": "fast", "fov": -3, "volume": 9, "keys": {"jump": 70, "quit_game": 65, "melee": "x"}}')
	f.close()
	store.load_file()
	eq(store.data["sens"], 1.0, "잘못된 형은 기본값")
	eq(store.data["fov"], 60.0, "범위 아래는 최소값")
	eq(store.data["volume"], 1.0, "범위 위는 최대값")
	eq(store.key_of(&"jump"), 70, "올바른 키 배치는 받는다")
	check(not (store.data["keys"] as Dictionary).has("quit_game"), "바꿀 수 없는 액션은 버린다")
	eq(store.key_of(&"melee"), KEY_V, "잘못된 키 값은 기본값")
	f = FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string("not json at all")
	f.close()
	store.load_file()
	eq(store.data["sens"], 1.0, "깨진 파일은 전부 기본값")


func test_rebinding_swaps_conflicting_keys() -> void:
	store.rebind(&"melee", KEY_E)   # E는 원래 상호작용
	eq(store.key_of(&"melee"), KEY_E, "근접 공격 → E")
	eq(store.key_of(&"interact"), KEY_V, "상호작용은 근접 공격이 쓰던 V를 넘겨받는다")
	store.rebind(&"jump", 0)
	eq(store.key_of(&"jump"), KEY_SPACE, "잘못된 키는 무시")
	store.reset_keys()
	eq(store.key_of(&"melee"), KEY_V, "기본값으로")


func test_keys_apply_to_input_map() -> void:
	store.rebind(&"jump", KEY_F)
	store.apply_keys()
	var events := InputMap.action_get_events(&"jump")
	eq(events.size(), 1, "바꾼 액션은 그 키 하나")
	eq((events[0] as InputEventKey).physical_keycode, KEY_F, "점프 → F")
	eq(InputMap.action_get_events(&"crouch").size(), 2, "바꾸지 않은 액션은 기본 배치(Ctrl, C) 유지")
	store.reset_keys()
	store.apply_keys()
	eq((InputMap.action_get_events(&"jump")[0] as InputEventKey).physical_keycode, KEY_SPACE, "되돌리면 기본 키")
