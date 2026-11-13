extends Node
## 오토로드. 접속(호스트/참가/싱글)과 플레이어 목록, 역할을 관리한다.
## 전송 종류(ENet, 나중에 Steam)를 아는 것은 이 파일뿐이다.

signal connected                      ## 월드에 들어갔다(호스트 시작, 싱글 시작, 참가 후 스냅샷 적용 완료)
signal disconnected(reason: String)
signal players_changed

const DEFAULT_PORT := 24565
const MAX_PLAYERS := 8

enum Role { OWNER, BUILDER, VISITOR }

## 피어 ID → {"name": String, "role": Role}. 모든 피어가 같은 내용을 갖는다.
var players: Dictionary = {}
var local_name: String = "Player"
var default_role: Role = Role.BUILDER
## 이름 → 역할. 역할이 세이브에 저장되기 전까지 쓰는 임시 지정 수단(테스트 포함).
var role_overrides: Dictionary[String, int] = {}
var in_world: bool = false


## 응답 없는 상대를 끊는 시간(ms). 기본값(최대 30초)보다 빨리 알아챈다.
const TIMEOUT_MIN_MS := 4000
const TIMEOUT_MAX_MS := 8000


func _ready() -> void:
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func() -> void: _leave("connection_failed"))
	multiplayer.server_disconnected.connect(func() -> void: _leave("host_closed"))


func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0.0"))


func my_id() -> int:
	return multiplayer.get_unique_id()


func is_host() -> bool:
	return multiplayer.is_server()


func role_of(peer_id: int) -> Role:
	var p: Dictionary = players.get(peer_id, {})
	return p.get("role", Role.VISITOR)


func may_build(peer_id: int) -> bool:
	return role_of(peer_id) != Role.VISITOR


## 혼자 플레이. 소켓을 열지 않으므로 네트워크 없이도 된다. 코드 경로는 호스트와 같다.
## 새 월드를 만들 때 쓸 난이도(시작 화면에서 고른다). 이어 하는 월드는 저장된 값을 쓴다.
var new_world_difficulty: String = "normal"


func start_single(world_id: String = "") -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_begin_hosting(world_id)


func host(port: int = DEFAULT_PORT, world_id: String = "") -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_begin_hosting(world_id)
	return OK


func join(address: String, port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		return err
	players.clear()
	multiplayer.multiplayer_peer = peer
	return OK


func leave() -> void:
	_leave("left")


## world_id가 있으면 그 세이브를 이어 하고, 없으면 새 월드를 만든다.
func _begin_hosting(world_id: String) -> void:
	players = {1: {"name": local_name, "role": Role.OWNER}}
	if world_id != "":
		var loaded := Save.load_world(world_id)
		if loaded.is_empty():
			var why := Save.store.last_error
			_leave("load_failed")
			disconnected.emit("세이브를 열 수 없습니다: %s" % why)
			return
		World.start_loaded(loaded["sim"], loaded["players"], loaded["settings"])
	else:
		Save.new_world("%s의 월드" % local_name)
		World.start_new()
		World.settings = {"difficulty": new_world_difficulty}
	in_world = true
	players_changed.emit()
	connected.emit()


func _leave(reason: String) -> void:
	var was_active := in_world or multiplayer.multiplayer_peer is ENetMultiplayerPeer
	# 호스트가 나갈 때는 저장하고 끝낸다.
	if in_world and multiplayer.is_server():
		Save.save_now(true)
	in_world = false
	World.stop()
	if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	players.clear()
	if was_active:
		disconnected.emit(reason)


# --- 접속 절차: 클라이언트가 버전과 콘텐츠 해시를 보내고, 호스트가 확인한 뒤 월드 스냅샷을 준다. ---

func _on_peer_connected(peer_id: int) -> void:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet != null and enet.get_peer(peer_id) != null:
		enet.get_peer(peer_id).set_timeout(0, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)


## 호스트가 지금까지 보낸 바이트 수(ENet일 때만, 부하 점검용). 읽으면 0으로 돌아간다.
func pop_sent_bytes() -> int:
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return int(enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)) if enet != null and enet.host != null else 0


func _on_connected_to_server() -> void:
	_hello.rpc_id(1, version(), Registry.db.content_hash(), local_name)


@rpc("any_peer", "call_remote", "reliable")
func _hello(their_version: String, their_hash: String, their_name: String) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if players.has(sender):
		return
	var reason := ""
	if their_version != version():
		reason = "version_mismatch:%s" % version()
	elif their_hash != Registry.db.content_hash():
		reason = "content_mismatch"
	elif players.size() >= MAX_PLAYERS:
		reason = "full"
	if reason != "":
		_rejected.rpc_id(sender, reason)
		# 거절 사유가 도착할 시간을 준 뒤 끊는다.
		get_tree().create_timer(0.5).timeout.connect(func() -> void:
			if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
				(multiplayer.multiplayer_peer as ENetMultiplayerPeer).disconnect_peer(sender))
		return
	var clean_name := their_name.strip_edges().left(24)
	if clean_name == "":
		clean_name = "Player %d" % players.size()
	# 이름이 소지품의 열쇠이므로 접속 중인 사람과 겹치면 번호를 붙인다(Steam ID로 바뀌기 전까지).
	var role: int = role_overrides.get(clean_name, default_role)
	var taken := true
	var suffix := 1
	var unique := clean_name
	while taken:
		taken = false
		for p: int in players:
			if (players[p] as Dictionary).get("name", "") == unique:
				taken = true
				suffix += 1
				unique = "%s (%d)" % [clean_name, suffix]
	players[sender] = {"name": unique, "role": role}
	World.send_snapshot(sender)
	World.register_player(sender)
	_players.rpc(players)
	players_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _rejected(reason: String) -> void:
	_leave("rejected:" + reason)


@rpc("authority", "call_remote", "reliable")
func _players(list: Dictionary) -> void:
	players = list
	players_changed.emit()


## World가 스냅샷 적용을 마치면 부른다(클라이언트).
func notify_snapshot_applied() -> void:
	if not in_world:
		in_world = true
		connected.emit()


func _on_peer_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	World.forget_peer(peer_id)
	if players.erase(peer_id):
		_players.rpc(players)
		players_changed.emit()
