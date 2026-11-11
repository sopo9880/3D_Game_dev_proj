class_name StructureView
extends Node3D
## 시뮬레이션의 구조물을 화면에 그린다(임시 상자 모델). 상태를 읽기만 한다.
## 벨트 위 물건은 MultiMesh 하나로 그리고, 틱 사이를 보간해 흐르는 것처럼 보이게 한다.

const KIND_COLORS: Dictionary[int, Color] = {
	StructureDef.Kind.NONE: Color(0.6, 0.6, 0.62),
	StructureDef.Kind.CRAFTER: Color(0.8, 0.55, 0.3),
	StructureDef.Kind.BELT: Color(0.25, 0.27, 0.3),
	StructureDef.Kind.JUNCTION: Color(0.55, 0.4, 0.75),
	StructureDef.Kind.STORAGE: Color(0.4, 0.6, 0.8),
	StructureDef.Kind.GENERATOR: Color(0.4, 0.75, 0.45),
	StructureDef.Kind.POWER_POLE: Color(0.85, 0.8, 0.4),
	StructureDef.Kind.FLOOR: Color(0.62, 0.6, 0.56),
	StructureDef.Kind.WALL: Color(0.7, 0.68, 0.62),
	StructureDef.Kind.STAIRS: Color(0.58, 0.56, 0.52),
	StructureDef.Kind.PLOT: Color(0.36, 0.26, 0.18),
	StructureDef.Kind.WORKBENCH: Color(0.6, 0.45, 0.3),
	StructureDef.Kind.DECOR: Color(0.75, 0.6, 0.45),
	-2: Color(0.35, 0.85, 0.5),
}
const ITEM_COLORS: Array[Color] = [
	Color(0.55, 0.45, 0.4), Color(0.8, 0.82, 0.86), Color(0.4, 0.9, 0.6), Color(0.6, 0.8, 0.3),
	Color(0.5, 0.7, 0.3), Color(0.5, 0.5, 0.5), Color(0.9, 0.7, 0.2), Color(0.6, 0.3, 0.8),
	Color(0.3, 0.8, 0.9), Color(1.0, 0.9, 0.4), Color(0.8, 0.6, 0.3), Color(0.8, 0.3, 0.3),
]
const MAX_ITEMS := 20000

var _nodes: Dictionary[int, Node3D] = {}
var _items: MultiMeshInstance3D
var _labels: Dictionary[int, Label3D] = {}
var _plants: Dictionary[int, MeshInstance3D] = {}
var _materials: Dictionary[int, StandardMaterial3D] = {}


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.4, 0.3, 0.4)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = MAX_ITEMS
	mm.visible_instance_count = 0
	_items = MultiMeshInstance3D.new()
	_items.multimesh = mm
	_items.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# 인스턴스가 넓게 퍼지므로 화면 밖으로 잘리지 않게 한다.
	_items.custom_aabb = AABB(Vector3(-5000, -100, -5000), Vector3(10000, 400, 10000))
	add_child(_items)
	World.reset.connect(rebuild)
	World.structure_added.connect(_add)
	World.structure_removed.connect(_remove)
	rebuild()


func rebuild() -> void:
	for id: int in _nodes:
		_nodes[id].queue_free()
	_nodes.clear()
	_labels.clear()
	_plants.clear()
	if World.sim == null:
		return
	for id: int in World.sim.structures:
		_add(World.sim.structures[id])


## 화면의 충돌체에서 구조물 ID를 얻는다. 구조물이 아니면 0.
static func structure_id_of(collider: Object) -> int:
	return int(collider.get_meta(&"structure_id", 0)) if collider != null else 0


## 구조물이 화면에서 차지하는 상자들: [[Transform3D, 크기], ...].
## 실제 표시와 건축 모드의 미리보기가 같은 계산을 쓴다.
static func shapes_for(def: StructureDef, cell: Vector3i, rot: int, belt_cells: Array[Vector3i] = [],
		free_pos_mm: Vector3i = Vector3i.ZERO, yaw_deg: int = 0) -> Array:
	var out: Array = []
	match def.kind:
		StructureDef.Kind.BELT:
			for c in belt_cells:
				out.append([Transform3D(Basis.IDENTITY, Vector3(c) + Vector3(0.5, 0.1, 0.5)), Vector3(1.0, 0.2, 1.0)])
		StructureDef.Kind.FLOOR:
			var size := Vector3(def.footprint.x, 0.2, def.footprint.z)
			out.append([Transform3D(Basis.IDENTITY, Vector3(cell) + Vector3(size.x * 0.5, 0.1, size.z * 0.5)), size])
		StructureDef.Kind.WALL:
			var w := float(def.footprint.x)
			var h := float(SimWorld.WALL_HEIGHT)
			if rot & 1 == 0:
				out.append([Transform3D(Basis.IDENTITY, Vector3(cell) + Vector3(w * 0.5, h * 0.5, 0.0)), Vector3(w, h, 0.2)])
			else:
				out.append([Transform3D(Basis.IDENTITY, Vector3(cell) + Vector3(0.0, h * 0.5, w * 0.5)), Vector3(0.2, h, w)])
		StructureDef.Kind.STAIRS:
			# 발자국의 경계 상자 안을 대각선으로 가로지르는 경사판. rot 0 = 남쪽(+Z)이 낮고 북쪽이 높다.
			var b := _bounds(def, cell, rot)
			var center: Vector3 = (b[0] + b[1]) * 0.5
			var run := float(def.footprint.z)
			var rise := float(def.footprint.y)
			var basis := Basis(Vector3.UP, -rot * PI * 0.5) * Basis(Vector3.RIGHT, atan2(rise, run))
			out.append([Transform3D(basis, center), Vector3(def.footprint.x, 0.2, sqrt(run * run + rise * rise))])
		StructureDef.Kind.DECOR:
			var sz: Array = def.params.get("size", [0.5, 0.5, 0.5])
			var size := Vector3(sz[0], sz[1], sz[2])
			var pos := Vector3(free_pos_mm) / 1000.0 + Vector3(0, size.y * 0.5, 0)
			out.append([Transform3D(Basis(Vector3.UP, deg_to_rad(float(yaw_deg))), pos), size])
		StructureDef.Kind.PLOT:
			var b := _bounds(def, cell, rot)
			var lo: Vector3 = b[0]
			var hi: Vector3 = b[1]
			out.append([Transform3D(Basis.IDENTITY, Vector3((lo.x + hi.x) * 0.5, lo.y + 0.12, (lo.z + hi.z) * 0.5)),
				Vector3(hi.x - lo.x - 0.1, 0.24, hi.z - lo.z - 0.1)])
		_:
			var b := _bounds(def, cell, rot)
			var inset := Vector3(0.06, 0.0, 0.06)
			out.append([Transform3D(Basis.IDENTITY, (b[0] + b[1]) * 0.5), b[1] - b[0] - inset * 2.0])
	return out


const PORT_COLORS: Array[Color] = [Color(0.3, 0.6, 1.0), Color(1.0, 0.6, 0.2), Color(0.75, 0.5, 1.0)]  # 입력, 출력, 겸용

## 포트 표시들: [[Transform3D, 입출력 종류], ...]. 포트가 있는 면 바깥에 화살표처럼 놓인다.
static func port_markers(def: StructureDef, cell: Vector3i, rot: int) -> Array:
	var out: Array = []
	for i in def.port_cells.size():
		var dir := (def.port_dirs[i] + rot) & 3
		var port_cell := cell + SimWorld.rotate_cell(def.port_cells[i], rot)
		var outward := Vector3(SimWorld.DIRV[dir])
		var pos := Vector3(port_cell) + Vector3(0.5, 0.45, 0.5) + outward * 0.62
		# 화살표가 물건이 흐르는 방향을 가리킨다: 출력은 바깥으로, 입력은 안으로.
		var flow := outward if def.port_ios[i] != StructureDef.PortIO.IN else -outward
		out.append([Transform3D(Basis.looking_at(flow, Vector3.UP), pos), def.port_ios[i]])
	return out


static func port_marker_node(marker: Array) -> MeshInstance3D:
	var mesh := PrismMesh.new()
	mesh.size = Vector3(0.5, 0.45, 0.12)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = PORT_COLORS[marker[1]]
	mi.material_override = mat
	# 프리즘의 꼭짓점(+Y)을 흐름 방향(-Z)으로 눕힌다.
	mi.transform = (marker[0] as Transform3D) * Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## 발자국(회전 반영)의 경계: [최소, 최대].
static func _bounds(def: StructureDef, cell: Vector3i, rot: int) -> Array[Vector3]:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for c in SimWorld.footprint_cells(def, cell, rot):
		lo = lo.min(Vector3(c))
		hi = hi.max(Vector3(c) + Vector3.ONE)
	return [lo, hi]


func _add(s: SimStructure) -> void:
	if _nodes.has(s.id):
		return
	var root := Node3D.new()
	add_child(root)
	_nodes[s.id] = root
	var top := Vector3.ZERO
	for shape: Array in shapes_for(s.def, s.cell, s.rot, s.cells, s.free_pos, s.free_yaw):
		_box(root, s, shape[0], shape[1])
		var t: Transform3D = shape[0]
		top = t.origin + Vector3(0, (shape[1] as Vector3).y * 0.5, 0)
	if s.kind != StructureDef.Kind.JUNCTION:
		for marker: Array in port_markers(s.def, s.cell, s.rot):
			root.add_child(port_marker_node(marker))
	match s.kind:
		StructureDef.Kind.BELT:
			# 흐르는 방향을 알 수 있게 끝에 표시를 둔다.
			var tip := Vector3(s.cells[-1]) + Vector3(0.5, 0.22, 0.5) + Vector3(SimWorld.DIRV[s.dir_out]) * 0.3
			var marker := _box(root, s, Transform3D(Basis.IDENTITY, tip), Vector3(0.3, 0.05, 0.3), false)
			marker.material_override = _material(-1)
		StructureDef.Kind.PLOT:
			# 작물: 자라는 만큼 커진다(_process에서 갱신).
			var plant := MeshInstance3D.new()
			var mesh := CylinderMesh.new()
			mesh.top_radius = 0.05
			mesh.bottom_radius = 0.45
			mesh.height = 1.0
			plant.mesh = mesh
			plant.material_override = _material(-2)
			plant.position = top
			plant.visible = false
			root.add_child(plant)
			_plants[s.id] = plant
		StructureDef.Kind.DECOR:
			if s.def.params.get("light", false):
				var light := OmniLight3D.new()
				light.light_color = Color(1.0, 0.85, 0.6)
				light.omni_range = 9.0
				light.light_energy = 1.5
				light.position = top + Vector3(0, 0.2, 0)
				root.add_child(light)
	if s.kind in [StructureDef.Kind.CRAFTER, StructureDef.Kind.STORAGE, StructureDef.Kind.GENERATOR,
			StructureDef.Kind.PLOT, StructureDef.Kind.WORKBENCH]:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.005
		label.font_size = 36
		label.outline_size = 10
		label.position = top + Vector3(0, 0.6 if s.kind != StructureDef.Kind.PLOT else 1.5, 0)
		if s.kind == StructureDef.Kind.WORKBENCH:
			label.text = "작업대"
		root.add_child(label)
		_labels[s.id] = label


func _remove(id: int) -> void:
	if _nodes.has(id):
		_nodes[id].queue_free()
		_nodes.erase(id)
		_labels.erase(id)
		_plants.erase(id)


func _box(root: Node3D, s: SimStructure, xform: Transform3D, size: Vector3, solid: bool = true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _material(s.kind)
	if not solid:
		mi.transform = xform
		root.add_child(mi)
		return mi
	var body := StaticBody3D.new()
	body.transform = xform
	body.set_meta(&"structure_id", s.id)
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	body.add_child(mi)
	root.add_child(body)
	return mi


func _material(kind: int) -> StandardMaterial3D:
	if not _materials.has(kind):
		var m := StandardMaterial3D.new()
		m.albedo_color = KIND_COLORS.get(kind, Color(0.95, 0.85, 0.3))
		m.roughness = 0.8
		_materials[kind] = m
	return _materials[kind]


func _process(_delta: float) -> void:
	var sim := World.sim
	if sim == null or not World.running:
		_items.multimesh.visible_instance_count = 0
		return
	var mm := _items.multimesh
	var n := 0
	var frac := World.tick_fraction()
	for l in sim.belts:
		if l.item_count == 0:
			continue
		var count := l.slots.size()
		# 다음 걸음까지 남은 비율만큼 앞칸 쪽으로 미리 움직여 보인다.
		var t := (float(sim.tick_count % l.period) + frac) / l.period
		for k in count:
			var v := l.slots[k]
			if v == 0:
				continue
			var here := Vector3(l.cells[count - 1 - k])
			var pos := here
			if k > 0 and l.slots[k - 1] == 0:
				pos = here.lerp(Vector3(l.cells[count - k]), t)
			if n >= MAX_ITEMS:
				break
			mm.set_instance_transform(n, Transform3D(Basis.IDENTITY, pos + Vector3(0.5, 0.36, 0.5)))
			mm.set_instance_color(n, ITEM_COLORS[(v - 1) % ITEM_COLORS.size()])
			n += 1
	mm.visible_instance_count = n

	# 설비 위 상태 표시 (자주 바뀌지 않으므로 몇 프레임에 한 번이면 충분하다).
	if Engine.get_process_frames() % 10 != 0:
		return
	for id: int in _labels:
		var s: SimStructure = sim.structures.get(id)
		if s == null:
			continue
		match s.kind:
			StructureDef.Kind.CRAFTER:
				_labels[id].text = ["대기", "가동", "재료 부족", "출력 막힘", "전력 부족", "레시피 없음"][s.state]
			StructureDef.Kind.STORAGE:
				var total := 0
				for item: int in s.store:
					total += s.store[item]
				_labels[id].text = "보관 %d" % total
			StructureDef.Kind.GENERATOR:
				_labels[id].text = "연료 %d%s" % [s.fuel_count, " · 연소 중" if s.burn_left > 0 else ""]
			StructureDef.Kind.PLOT:
				var plant: MeshInstance3D = _plants.get(id)
				if s.crop < 0:
					_labels[id].text = ""
					if plant != null:
						plant.visible = false
					continue
				var crop := sim.db.crops[s.crop]
				var grown := clampf(float(s.growth) / crop.grow_ticks, 0.0, 1.0)
				_labels[id].text = "수확 가능" if grown >= 1.0 else "%d%%%s" % [int(grown * 100.0), " · 물 줌" if s.watered else ""]
				if plant != null:
					plant.visible = true
					var h := lerpf(0.15, 1.2, grown)
					plant.scale = Vector3(lerpf(0.3, 1.0, grown), h, lerpf(0.3, 1.0, grown))
					plant.position.y = float(s.cell.y) + 0.24 + h * 0.5
