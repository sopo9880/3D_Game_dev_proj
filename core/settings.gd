extends Node
## 오토로드. 플레이어 설정을 읽어 적용하고, 바뀌면 저장한다.

signal changed

var store: SettingsStore


func _ready() -> void:
	store = SettingsStore.new()
	store.load_file()
	apply()


func get_value(key: String) -> Variant:
	return store.data.get(key, SettingsStore.DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	store.set_value(key, value)
	apply()
	store.save_file()


func rebind(action: StringName, keycode: int) -> void:
	store.rebind(action, keycode)
	apply()
	store.save_file()


func reset_keys() -> void:
	store.reset_keys()
	apply()
	store.save_file()


## 설정을 엔진에 반영한다. 화면이 없는 환경에서는 창 관련 설정을 건너뛴다.
func apply() -> void:
	store.apply_keys()
	var volume := float(store.data["volume"])
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(0, volume <= 0.001)
	if DisplayServer.get_name() != "headless":
		var want_full := bool(store.data["fullscreen"])
		var is_full := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
		if want_full != is_full:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if want_full else DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(store.data["vsync"]) else DisplayServer.VSYNC_DISABLED)
	changed.emit()
