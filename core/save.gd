extends Node
## 오토로드. 호스트의 월드를 파일로 저장하고 불러온다.
## 저장은 틱 사이에 상태를 복사한 뒤 별도 스레드에서 파일로 쓴다(프레임이 끊기지 않게).

signal saved(ok: bool, message: String)

const AUTOSAVE_SECONDS := 300.0

var store: SaveStore
var world_id: String = ""
var world_name: String = ""
var autosave_enabled: bool = true
var last_saved_at: float = 0.0

var _thread: Thread
var _timer: float = 0.0


func _ready() -> void:
	store = SaveStore.new()


func set_root(root: String) -> void:
	store = SaveStore.new(root)


func new_world(display_name: String) -> void:
	world_id = SaveStore.new_id()
	world_name = display_name
	_timer = 0.0


## 저장된 월드를 읽어 시뮬레이션으로 만든다. {"sim": SimWorld, "players": Dictionary}. 실패하면 빈 사전.
func load_world(id: String) -> Dictionary:
	var data := store.read(id)
	if data.is_empty():
		return {}
	var sim_data: Variant = data.get("sim")
	var migrated := SaveMigrations.migrate_sim(sim_data) if sim_data is Dictionary else {}
	var sim: SimWorld = SimWorld.from_dict(Registry.db, migrated) if not migrated.is_empty() else null
	if sim == null:
		store.last_error = "월드 데이터의 형식을 읽을 수 없음"
		return {}
	var manifest := store.read_manifest(id)
	world_id = id
	world_name = str(manifest.get("name", id))
	_timer = 0.0
	return {"sim": sim, "players": data.get("players", {})}


func is_saving() -> bool:
	return _thread != null and _thread.is_alive()


## 지금 저장한다(호스트만). blocking이면 끝날 때까지 기다린다(종료 직전용).
func save_now(blocking: bool = false) -> bool:
	if world_id == "" or not World.running or not multiplayer.is_server():
		return false
	if _thread != null:
		if _thread.is_alive() and not blocking:
			return false   # 이전 저장이 아직 쓰는 중
		_thread.wait_to_finish()
		_thread = null
	# 여기서 상태를 복사한다. 이후의 변경은 이번 저장에 섞이지 않는다.
	var data := {"sim": World.sim.to_dict(), "players": World.positions_for_save()}
	var ticks := World.sim.tick_count
	_timer = 0.0
	if blocking:
		var ok := store.write(world_id, world_name, data, ticks)
		_done(ok, store.last_error)
		return ok
	_thread = Thread.new()
	_thread.start(_write.bind(store.root, world_id, world_name, data, ticks))
	return true


func _write(root: String, id: String, display_name: String, data: Dictionary, ticks: int) -> void:
	var s := SaveStore.new(root)
	var ok := s.write(id, display_name, data, ticks)
	_done.call_deferred(ok, s.last_error)


func _done(ok: bool, message: String) -> void:
	if ok:
		last_saved_at = Time.get_ticks_msec() / 1000.0
	else:
		push_error("[Save] 저장 실패: %s" % message)
	saved.emit(ok, message)


func _process(delta: float) -> void:
	if not autosave_enabled or world_id == "" or not World.running or not multiplayer.is_server():
		return
	_timer += delta
	if _timer >= AUTOSAVE_SECONDS:
		save_now()


func _notification(what: int) -> void:
	# 창을 닫을 때도 저장한다.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_now(true)


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
