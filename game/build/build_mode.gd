class_name BuildMode
extends Node3D
## 건축 모드: 집, 정원, 공장을 한 가지 도구로 짓는다.
##   B 켜고 끄기 · Tab 탭 · 휠 종류 선택 · R 회전 · 좌클릭 설치 · 우클릭/Esc 취소
##   X 조준한 것 철거 · F 조준한 것과 같은 종류 선택 · Z 되돌리기
## 여기서는 미리보기와 요청만 한다. 설치할 수 있는지는 호스트가 다시 판단한다.

const REACH := 14.0
const UNDO_LIMIT := 20
## 지을 수 있는 것들. 탭은 데이터의 tab 값으로 나뉜다.
const CATALOG: Array[StringName] = [
	&"floor", &"wall", &"stairs", &"roof",
	&"belt", &"junction", &"miner", &"smelter", &"assembler", &"storage", &"bio_generator", &"power_pole", &"workbench",
	&"plot", &"planter", &"fence",
	&"chair", &"table", &"lamp",
]
const TAB_ORDER: Array[StringName] = [&"building", &"industry", &"nature", &"interior"]
const TAB_NAMES: Dictionary[StringName, String] = {
	&"building": "건물", &"industry": "산업", &"nature": "자연", &"interior": "인테리어",
}
const REASONS: Dictionary[String, String] = {
	"": "", "occupied": "자리가 차 있음", "no_support": "받침이 없음", "needs_node": "광맥 위에만 설치",
	"out_of_bounds": "범위 밖", "cannot_afford": "재료 부족", "no_permission": "권한 없음(방문자)",
	"too_far": "너무 멀다", "not_adjacent": "벨트가 이어지지 않음", "no_target": "설치할 곳을 조준하세요",
	"too_many": "장식이 너무 많음", "need_workbench": "작업대 근처에서만", "not_found": "대상이 없음",
	"bad_request": "잘못된 요청", "unknown_structure": "모르는 구조물", "full": "가득 참",
	"not_buildable": "건축할 수 없는 땅",
}

var player: PlayerController
var hud: Hud
var active: bool = false
var tab: int = 0
var index: int = 0                          ## 탭 안에서의 순서
var rot: int = 0
var yaw_step: int = 0                       ## 장식 회전(15도 단위)
var reason: String = "no_target"            ## 지금 미리보기 자리에 설치할 수 없는 이유("" = 가능)

var _ghost: Node3D
var _ghost_ok: StandardMaterial3D
var _ghost_bad: StandardMaterial3D
var _target: Dictionary = {}                ## 현재 미리보기: {"cell", "rot", "path", "pos"}
var _belt_start: Variant = null             ## 벨트 시작 칸(Vector3i). 아직 안 찍었으면 null
var _undo: Array[Dictionary] = []           ## 내가 한 일: {"op": "place", "id"} 또는 {"op": "remove", ...}
var _pending: Array[Dictionary] = []        ## 설치를 요청하고 결과를 기다리는 것
var _tabs: Array = []                       ## 탭마다의 구조물 ID 목록


func _ready() -> void:
	for t in TAB_ORDER:
		var ids: Array[StringName] = []
		for id in CATALOG:
			if Registry.db.structures[id].tab == t:
				ids.append(id)
		_tabs.append(ids)
	_ghost = Node3D.new()
	_ghost.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_ghost)
	_ghost_ok = _ghost_material(Color(0.3, 1.0, 0.5, 0.45))
	_ghost_bad = _ghost_material(Color(1.0, 0.3, 0.25, 0.45))
	World.structure_added.connect(_on_structure_added)
	World.request_rejected.connect(func(why: String) -> void:
		_pending.clear()
		hud.toast(reason_text(why)))


static func reason_text(why: String) -> String:
	return REASONS.get(why, why)


func selected() -> StructureDef:
	var ids: Array[StringName] = _tabs[tab]
	return Registry.db.structures[ids[index % ids.size()]]


func set_active(on: bool) -> void:
	active = on
	player.suppress_combat = on
	_belt_start = null
	_ghost.visible = on
	if not on:
		hud.build_text = ""


func select(def_id: StringName) -> void:
	for t in _tabs.size():
		var i := (_tabs[t] as Array[StringName]).find(def_id)
		if i >= 0:
			tab = t
			index = i
			_belt_start = null
			return


func _step(delta_index: int) -> void:
	var count := (_tabs[tab] as Array).size()
	index = posmod(index + delta_index, count)
	_belt_start = null


func next_tab() -> void:
	tab = (tab + 1) % _tabs.size()
	index = 0
	_belt_start = null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"build_toggle") and player.input_enabled and not player.downed:
		set_active(not active)
		return
	if not active or not player.is_active():
		return
	if event.is_action_pressed(&"weapon_next"):
		_step(1)
	elif event.is_action_pressed(&"weapon_prev"):
		_step(-1)
	elif event.is_action_pressed(&"build_tab"):
		next_tab()
	elif event.is_action_pressed(&"pause"):
		set_active(false)
	elif event.is_action_pressed(&"reload"):
		rot = (rot + 1) & 3
		yaw_step = (yaw_step + 1) % 24
	elif event.is_action_pressed(&"fire"):
		confirm()
	elif event.is_action_pressed(&"aim"):
		if _belt_start != null:
			_belt_start = null
		else:
			set_active(false)
	elif event.is_action_pressed(&"dev_remove"):
		remove_aimed()
	elif event.is_action_pressed(&"build_pick"):
		pick_aimed()
	elif event.is_action_pressed(&"build_undo"):
		undo()
	else:
		return
	get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not active or World.sim == null:
		return
	var aim := _aim()
	update_target(aim.get("position", Vector3.ZERO), aim.get("normal", Vector3.UP), not aim.is_empty())
	_draw_ghost()
	var def := selected()
	var cost := World.sim.build_cost(def, (_target.get("path", []) as Array).size())
	var parts: PackedStringArray = []
	for item: int in cost:
		parts.append("%s %d/%d" % [Registry.db.item_def(item).display_name, World.sim.inv_count(World.my_key(), item), cost[item]])
	var hint := ""
	if def.kind == StructureDef.Kind.BELT:
		hint = "끝점을 클릭" if _belt_start != null else "시작점을 클릭"
	var tab_line: PackedStringArray = []
	for t in TAB_ORDER.size():
		tab_line.append(("[%s]" if t == tab else "%s") % TAB_NAMES[TAB_ORDER[t]])
	hud.build_text = "%s   (Tab)\n%s  %d/%d   비용: %s\n%s%s" % [
		"  ".join(tab_line), _display_name(def), index + 1, (_tabs[tab] as Array).size(), ", ".join(parts),
		reason_text(reason) if reason != "" else "설치 가능", "  ·  " + hint if hint != "" else ""]


# ---------------------------------------------------------------------------
# 미리보기 자리 계산 (화면 없이도 부를 수 있다)
# ---------------------------------------------------------------------------

## 조준점에서 설치 자리를 정하고, 그 자리에 설치할 수 있는지 판단한다.
func update_target(hit_pos: Vector3, hit_normal: Vector3, has_hit: bool) -> void:
	_target = {}
	if not has_hit:
		reason = "no_target"
		return
	var def := selected()
	var sim := World.sim
	var p := hit_pos + hit_normal * 0.02
	# 그 자리의 지면 높이(건축 구역의 단). 구역 밖이면 0으로 두고, 설치 가능 여부는 아래에서 걸러진다.
	var base := sim.ground_y(floori(p.x), floori(p.z))
	if base == SimWorld.NO_GROUND:
		base = 0
	var c := Vector3i(floori(p.x), maxi(floori(p.y), base), floori(p.z))
	var key := World.my_key()
	match def.kind:
		StructureDef.Kind.FLOOR:
			var cell := Vector3i(floori(p.x / 4.0) * 4, base + maxi(roundi((p.y - base) / 4.0), 0) * 4, floori(p.z / 4.0) * 4)
			_target = {"cell": cell, "rot": 0}
			reason = sim.can_place(def.id, cell, 0)
		StructureDef.Kind.WALL:
			# 바라보는 방향과 직각으로 선다. R을 누르면 방향을 바꾼다.
			var facing_z := absf(sin(player.yaw)) < 0.7071
			var along_x := facing_z != (rot & 1 == 1)
			var y := base + maxi(floori((p.y - base) / 4.0), 0) * 4
			var cell := Vector3i(floori(p.x / 4.0) * 4, y, roundi(p.z / 4.0) * 4) if along_x \
					else Vector3i(roundi(p.x / 4.0) * 4, y, floori(p.z / 4.0) * 4)
			_target = {"cell": cell, "rot": 0 if along_x else 1}
			reason = sim.can_place(def.id, cell, _target["rot"])
		StructureDef.Kind.STAIRS:
			var corner := Vector3i(floori(p.x / 4.0) * 4, base + maxi(floori((p.y - base) / 4.0), 0) * 4, floori(p.z / 4.0) * 4)
			# 회전해도 같은 4×4 자리를 차지하도록 원점을 옮긴다.
			const STAIR_OFFSETS: Array[Vector3i] = [Vector3i.ZERO, Vector3i(3, 0, 0), Vector3i(3, 0, 3), Vector3i(0, 0, 3)]
			var cell: Vector3i = corner + STAIR_OFFSETS[rot]
			_target = {"cell": cell, "rot": rot}
			reason = sim.can_place(def.id, cell, rot)
		StructureDef.Kind.DECOR:
			var pos_mm := Vector3i((p * 1000.0).round())
			_target = {"pos": pos_mm, "yaw": yaw_step * 15}
			reason = sim.can_place_free(def.id, pos_mm)
		StructureDef.Kind.BELT:
			if _belt_start == null:
				_target = {"path": [c] as Array[Vector3i]}
				reason = sim.can_place_belt([c] as Array[Vector3i], 0)
			else:
				var path := belt_path(_belt_start, Vector3i(c.x, (_belt_start as Vector3i).y, c.z))
				_target = {"path": path}
				reason = sim.can_place_belt(path, rot if path.size() == 1 else -1)
		_:
			var half := Vector3i(def.footprint.x / 2, 0, def.footprint.z / 2)
			var cell := c - SimWorld.rotate_cell(half, rot)
			_target = {"cell": cell, "rot": rot}
			reason = sim.can_place(def.id, cell, rot)
	if reason == "" and not Net.may_build(Net.my_id()):
		reason = "no_permission"
	if reason == "" and not sim.can_afford(key, sim.build_cost(def, (_target.get("path", []) as Array).size())):
		reason = "cannot_afford"


## 시작 칸에서 끝 칸까지 ㄱ자 벨트 경로. 양 끝이 포트 앞이면 포트에서 곧게 나오고 들어가는 쪽을 고른다.
func belt_path(from: Vector3i, to: Vector3i) -> Array[Vector3i]:
	var options: Array = [_leg_path(from, to, true), _leg_path(from, to, false)]
	var sim := World.sim
	var out_dir := sim.port_dir_at(from, true)
	var in_dir := sim.port_dir_at(to, false)
	var best: Array[Vector3i] = options[0]
	var best_score := -1
	for o: Array[Vector3i] in options:
		if o.size() < 2:
			return o
		var score := 0
		if out_dir >= 0 and SimWorld.DIRV[out_dir] == o[1] - o[0]:
			score += 1
		if in_dir >= 0 and SimWorld.DIRV[(in_dir + 2) & 3] == o[-1] - o[-2]:
			score += 1
		if score > best_score:
			best_score = score
			best = o
	return best


func _leg_path(from: Vector3i, to: Vector3i, x_first: bool) -> Array[Vector3i]:
	var out: Array[Vector3i] = [from]
	var cur := from
	for axis: int in ([0, 2] if x_first else [2, 0]):
		while cur[axis] != to[axis]:
			cur[axis] += signi(to[axis] - cur[axis])
			out.append(cur)
	return out


# ---------------------------------------------------------------------------
# 동작
# ---------------------------------------------------------------------------

## 지금 미리보기 자리에 설치를 요청한다. 요청을 보냈으면 true.
func confirm() -> bool:
	var def := selected()
	if def.kind == StructureDef.Kind.BELT and _belt_start == null:
		if reason != "" or _target.is_empty():
			hud.toast(reason_text(reason))
			return false
		_belt_start = (_target["path"] as Array)[0]
		return false
	if reason != "" or _target.is_empty():
		hud.toast(reason_text(reason))
		return false
	_pending.append({"def": def.id})
	match def.kind:
		StructureDef.Kind.BELT:
			var path: Array[Vector3i] = _target["path"]
			World.request_place_belt(def.id, path, rot if path.size() == 1 else -1)
			_belt_start = null
		StructureDef.Kind.DECOR:
			World.request("free", [String(def.id), _target["pos"], _target["yaw"]])
		_:
			World.request_place(def.id, _target["cell"], _target["rot"])
	return true


func remove_aimed() -> bool:
	var id := StructureView.structure_id_of(_aim().get("collider"))
	return remove(id)


func remove(id: int) -> bool:
	var s: SimStructure = World.sim.structures.get(id)
	if s == null:
		return false
	_push_undo({"op": "remove", "def": s.def.id, "cell": s.cell, "rot": s.rot, "path": s.cells.duplicate(),
		"dir": s.dir_out, "pos": s.free_pos, "yaw": s.free_yaw})
	World.request_remove(id)
	return true


func pick_aimed() -> void:
	var s: SimStructure = World.sim.structures.get(StructureView.structure_id_of(_aim().get("collider")))
	if s != null:
		select(s.def.id)
		rot = s.rot


## 내가 방금 한 설치나 철거를 되돌린다. 그 사이 상황이 바뀌었으면 호스트가 거절한다.
func undo() -> bool:
	if _undo.is_empty():
		hud.toast("되돌릴 것이 없습니다")
		return false
	var u: Dictionary = _undo.pop_back()
	if u["op"] == "place":
		if not World.sim.structures.has(u["id"]):
			hud.toast("이미 없어졌습니다")
			return false
		World.request_remove(u["id"])
		return true
	var def: StructureDef = Registry.db.structures[u["def"]]
	match def.kind:
		StructureDef.Kind.BELT:
			var path: Array[Vector3i] = []
			path.assign(u["path"])
			World.request_place_belt(def.id, path, u["dir"])
		StructureDef.Kind.DECOR:
			World.request("free", [String(def.id), u["pos"], u["yaw"]])
		_:
			World.request_place(def.id, u["cell"], u["rot"])
	return true


func undo_count() -> int:
	return _undo.size()


func _on_structure_added(s: SimStructure) -> void:
	# 내가 요청한 설치가 받아들여졌다. 되돌리기 목록에 올린다.
	if s.placed_by != World.my_key() or _pending.is_empty():
		return
	for i in _pending.size():
		if _pending[i]["def"] == s.def.id:
			_pending.remove_at(i)
			_push_undo({"op": "place", "id": s.id})
			return


func _push_undo(u: Dictionary) -> void:
	_undo.append(u)
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()


func _aim() -> Dictionary:
	var from := player.camera.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - player.camera.global_basis.z * REACH, 1)
	q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)


func _draw_ghost() -> void:
	for c in _ghost.get_children():
		c.queue_free()
	if _target.is_empty():
		return
	var def := selected()
	var path: Array[Vector3i] = []
	path.assign(_target.get("path", []))
	var shapes := StructureView.shapes_for(def, _target.get("cell", Vector3i.ZERO), _target.get("rot", 0),
		path, _target.get("pos", Vector3i.ZERO), _target.get("yaw", 0))
	for shape: Array in shapes:
		var mesh := BoxMesh.new()
		mesh.size = (shape[1] as Vector3) + Vector3.ONE * 0.02
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = _ghost_ok if reason == "" else _ghost_bad
		mi.transform = shape[0]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ghost.add_child(mi)
	# 입력·출력 포트가 어느 쪽인지 설치 전에 보여 준다.
	for marker: Array in StructureView.port_markers(def, _target.get("cell", Vector3i.ZERO), _target.get("rot", 0)):
		_ghost.add_child(StructureView.port_marker_node(marker))


func _ghost_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


static func _display_name(def: StructureDef) -> String:
	const NAMES: Dictionary[StringName, String] = {
		&"floor": "바닥", &"wall": "벽", &"stairs": "계단", &"roof": "지붕", &"belt": "벨트",
		&"junction": "분배/합류기", &"miner": "채굴기", &"smelter": "제련기", &"assembler": "조립기",
		&"storage": "저장소", &"bio_generator": "바이오 발전기", &"power_pole": "전력 중계 기둥",
		&"workbench": "작업대", &"plot": "밭", &"chair": "의자", &"table": "탁자", &"lamp": "등불",
		&"planter": "화분", &"fence": "울타리", &"beacon": "복원 비콘",
	}
	return NAMES.get(def.id, String(def.id))
