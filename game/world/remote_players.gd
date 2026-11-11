class_name RemotePlayers
extends Node3D
## 다른 플레이어의 아바타(임시 캡슐). 받은 위치를 향해 부드럽게 따라간다.

var seen: Dictionary[int, bool] = {}     ## 위치를 한 번이라도 받은 피어 (점검용)

var _avatars: Dictionary[int, Node3D] = {}
var _targets: Dictionary[int, Array] = {}  ## 피어 → [위치, yaw, 앉기]


func _ready() -> void:
	World.remote_player_state.connect(_on_state)
	Net.players_changed.connect(_prune)


func _on_state(peer_id: int, pos: Vector3, yaw: float, _pitch: float, crouch: bool) -> void:
	if peer_id == Net.my_id():
		return
	seen[peer_id] = true
	if not _avatars.has(peer_id):
		_avatars[peer_id] = _make_avatar(peer_id)
		_avatars[peer_id].position = pos
	_targets[peer_id] = [pos, yaw, crouch]


func _process(delta: float) -> void:
	var k := 1.0 - exp(-14.0 * delta)
	for peer_id: int in _avatars:
		var a := _avatars[peer_id]
		var t: Array = _targets[peer_id]
		var target: Vector3 = t[0]
		# 너무 멀면(순간이동, 부활) 보간하지 않고 바로 옮긴다.
		a.position = target if a.position.distance_to(target) > 8.0 else a.position.lerp(target, k)
		a.rotation.y = lerp_angle(a.rotation.y, t[1], k)
		a.scale.y = lerpf(a.scale.y, 0.62 if t[2] else 1.0, k)


func _prune() -> void:
	for peer_id: int in _avatars.keys():
		if not Net.players.has(peer_id):
			_avatars[peer_id].queue_free()
			_avatars.erase(peer_id)
			_targets.erase(peer_id)


func _make_avatar(peer_id: int) -> Node3D:
	var root := Node3D.new()
	root.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(fmod(peer_id * 0.618, 1.0), 0.55, 0.9)
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	body.mesh = capsule
	body.material_override = mat
	body.position.y = 0.9
	root.add_child(body)
	var visor := MeshInstance3D.new()
	var visor_mesh := BoxMesh.new()
	visor_mesh.size = Vector3(0.4, 0.12, 0.2)
	visor.mesh = visor_mesh
	visor.position = Vector3(0, 1.55, -0.28)
	root.add_child(visor)
	var label := Label3D.new()
	label.text = str((Net.players.get(peer_id, {}) as Dictionary).get("name", "?"))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 2.15
	label.pixel_size = 0.005
	label.font_size = 40
	label.outline_size = 10
	root.add_child(label)
	add_child(root)
	return root
