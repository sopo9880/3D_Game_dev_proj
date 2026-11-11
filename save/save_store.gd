class_name SaveStore
extends RefCounted
## 월드 저장 파일을 읽고 쓴다. 씬과 무관하므로 테스트에서 임시 폴더로 바로 쓸 수 있다.
##
## 구조 (root 아래):
##   <id>/manifest.json   사람이 읽을 수 있는 요약
##   <id>/world.bin       압축한 월드 데이터(기본형만 담은 사전)
##   <id>.tmp/            쓰는 중인 새 저장
##   <id>.backups/<시각>/ 이전 저장들 (최근 MAX_BACKUPS개)
##
## 쓰기는 임시 폴더에 전부 쓴 뒤 검증하고, 기존 폴더를 백업으로 옮긴 다음 이름을 바꾼다.
## 어느 시점에 꺼져도 직전 저장이나 새 저장 중 하나는 온전하게 남는다.

const SAVE_VERSION := 1          ## 파일 구성의 버전. 월드 데이터 안의 형식은 SimWorld.SAVE_FORMAT
const MAX_BACKUPS := 5

var root: String
var last_error: String = ""


func _init(root_dir: String = "user://worlds") -> void:
	root = root_dir
	DirAccess.make_dir_recursive_absolute(root)


static func new_id() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%08x" % [rng.randi(), rng.randi()]


## 저장된 월드들의 요약(최근 저장 순). 쓰다 만 저장은 복구하거나 무시한다.
func list_worlds() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary[String, bool] = {}
	for d in DirAccess.get_directories_at(root):
		var id := d.trim_suffix(".tmp").trim_suffix(".backups")
		if seen.has(id):
			continue
		seen[id] = true
		_recover(id)
		var m := read_manifest(id)
		if not m.is_empty():
			out.append(m)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["saved_at"]) > int(b["saved_at"]))
	return out


func read_manifest(id: String) -> Dictionary:
	return _read_manifest_at(root.path_join(id))


## 월드를 저장한다. data는 기본형만 담은 사전이어야 한다. 성공하면 true.
func write(id: String, world_name: String, data: Dictionary, play_ticks: int) -> bool:
	last_error = ""
	var dir := root.path_join(id)
	var tmp := dir + ".tmp"
	_remove_dir(tmp)
	if DirAccess.make_dir_recursive_absolute(tmp) != OK:
		return _fail("임시 폴더를 만들 수 없음")
	var manifest := {
		"save_version": SAVE_VERSION, "world_id": id, "name": world_name,
		"game_version": str(ProjectSettings.get_setting("application/config/version", "?")),
		"saved_at": int(Time.get_unix_time_from_system()), "play_ticks": play_ticks,
	}
	var raw := var_to_bytes(data)
	var f := FileAccess.open(tmp.path_join("world.bin"), FileAccess.WRITE)
	if f == null:
		return _fail("world.bin을 쓸 수 없음")
	f.store_32(raw.size())
	f.store_buffer(raw.compress(FileAccess.COMPRESSION_ZSTD))
	f.close()
	f = FileAccess.open(tmp.path_join("manifest.json"), FileAccess.WRITE)
	if f == null:
		return _fail("manifest.json을 쓸 수 없음")
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()
	# 방금 쓴 것을 다시 읽어 본다.
	if _read_manifest_at(tmp).is_empty() or _read_data_at(tmp).is_empty():
		return _fail("쓴 파일을 다시 읽을 수 없음")
	# 교체: 기존 → 백업, 임시 → 제자리.
	if DirAccess.dir_exists_absolute(dir):
		var backups := dir + ".backups"
		DirAccess.make_dir_recursive_absolute(backups)
		var stamp := "%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000]
		if DirAccess.rename_absolute(dir, backups.path_join(stamp)) != OK:
			return _fail("기존 저장을 백업으로 옮길 수 없음")
	if DirAccess.rename_absolute(tmp, dir) != OK:
		return _fail("새 저장을 제자리로 옮길 수 없음")
	_prune_backups(id)
	return true


## 월드 데이터를 읽는다. 본 저장이 깨졌으면 가장 최근 백업을 쓴다. 읽을 수 없으면 빈 사전.
func read(id: String) -> Dictionary:
	last_error = ""
	_recover(id)
	var dir := root.path_join(id)
	var m := _read_manifest_at(dir)
	if not m.is_empty() and int(m.get("save_version", 0)) > SAVE_VERSION:
		last_error = "이 세이브는 더 새로운 게임 버전(%s)에서 만들어졌습니다" % m.get("game_version", "?")
		return {}
	var data := _read_data_at(dir)
	if not data.is_empty():
		return data
	for stamp in _backup_stamps(id):
		data = _read_data_at((dir + ".backups").path_join(stamp))
		if not data.is_empty():
			last_error = "본 저장을 읽을 수 없어 백업(%s)을 불러왔습니다" % stamp
			return data
	if last_error == "":
		last_error = "세이브를 읽을 수 없음"
	return {}


func backup_count(id: String) -> int:
	return _backup_stamps(id).size()


func delete(id: String) -> void:
	var dir := root.path_join(id)
	_remove_dir(dir)
	_remove_dir(dir + ".tmp")
	_remove_dir(dir + ".backups")


# ---------------------------------------------------------------------------

## 저장 도중 꺼진 흔적을 정리한다.
func _recover(id: String) -> void:
	var dir := root.path_join(id)
	var tmp := dir + ".tmp"
	if DirAccess.dir_exists_absolute(dir):
		_remove_dir(tmp)   # 쓰다 만 것은 버린다. 직전 저장이 온전하다.
		return
	# 기존을 백업으로 옮긴 직후 꺼진 경우: 임시가 온전하면 그것이 새 저장이다.
	if DirAccess.dir_exists_absolute(tmp):
		if not _read_manifest_at(tmp).is_empty() and not _read_data_at(tmp).is_empty():
			DirAccess.rename_absolute(tmp, dir)
			return
		_remove_dir(tmp)
	# 아니면 가장 최근 백업을 되살린다.
	for stamp in _backup_stamps(id):
		var b := (dir + ".backups").path_join(stamp)
		if not _read_manifest_at(b).is_empty() and not _read_data_at(b).is_empty():
			DirAccess.rename_absolute(b, dir)
			return


func _read_manifest_at(dir: String) -> Dictionary:
	var path := dir.path_join("manifest.json")
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary or not (parsed as Dictionary).has("world_id"):
		return {}
	return parsed


func _read_data_at(dir: String) -> Dictionary:
	var path := dir.path_join("world.bin")
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null or f.get_length() < 8:
		return {}
	var raw_size := f.get_32()
	var packed := f.get_buffer(f.get_length() - 4)
	f.close()
	if raw_size <= 0 or raw_size > 512 * 1024 * 1024:
		return {}
	var raw := packed.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != raw_size:
		return {}
	# 객체를 풀지 않는 bytes_to_var만 쓴다: 남이 준 세이브가 코드를 실행할 길을 만들지 않는다.
	var parsed: Variant = bytes_to_var(raw)
	return parsed if parsed is Dictionary else {}


## 백업 폴더 이름들(최근 것 먼저).
func _backup_stamps(id: String) -> Array[String]:
	var out: Array[String] = []
	var backups := root.path_join(id) + ".backups"
	if DirAccess.dir_exists_absolute(backups):
		for d in DirAccess.get_directories_at(backups):
			out.append(d)
	out.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) > 0)
	return out


func _prune_backups(id: String) -> void:
	var stamps := _backup_stamps(id)
	for i in range(MAX_BACKUPS, stamps.size()):
		_remove_dir((root.path_join(id) + ".backups").path_join(stamps[i]))


func _remove_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_remove_dir(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _fail(msg: String) -> bool:
	last_error = msg
	return false
