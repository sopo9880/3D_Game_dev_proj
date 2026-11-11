class_name CombatYard
extends NavigationRegion3D
## 시험용 전투 구역(회색 상자). 엄폐물, 파쿠르 지형, 적 출현 지점이 있다.
## 지형은 이 노드의 자식이어야 길찾기 메시에 포함된다.

const GRID_SHADER := preload("res://game/range/grid.gdshader")
## 구역 범위 (x 최소, z 최소, x 크기, z 크기)
const BOUNDS := Rect2(-32, 14, 64, 62)

var spawn_points: Array[Vector3] = []
var crate_position: Vector3 = Vector3(4, 0, 6)


func _ready() -> void:
	var floor_color := Color(0.42, 0.36, 0.34)
	var wall := Color(0.42, 0.42, 0.48)
	var block := Color(0.55, 0.48, 0.38)
	var cx := BOUNDS.position.x + BOUNDS.size.x * 0.5
	var cz := BOUNDS.position.y + BOUNDS.size.y * 0.5
	# 바닥판(전역 바닥보다 살짝 높다)과 둘레 벽. 입구는 남쪽(z가 작은 쪽) 가운데.
	_box(Vector3(cx, -0.22, cz), Vector3(BOUNDS.size.x, 0.5, BOUNDS.size.y), floor_color)
	_box(Vector3(cx, 2.5, BOUNDS.end.y), Vector3(BOUNDS.size.x, 5, 0.6), wall)
	_box(Vector3(BOUNDS.position.x, 2.5, cz), Vector3(0.6, 5, BOUNDS.size.y), wall)
	_box(Vector3(BOUNDS.end.x, 2.5, cz), Vector3(0.6, 5, BOUNDS.size.y), wall)
	_box(Vector3(-19, 2.5, BOUNDS.position.y), Vector3(26, 5, 0.6), wall)
	_box(Vector3(19, 2.5, BOUNDS.position.y), Vector3(26, 5, 0.6), wall)

	# 엄폐물
	for spec: Array in [[-8, 24, 3, 1.2, 0.6], [7, 28, 0.6, 1.2, 3], [-3, 36, 4, 1.2, 0.6], [12, 40, 3, 1.2, 0.6],
			[-14, 44, 0.6, 1.2, 4], [2, 50, 5, 1.2, 0.6], [-9, 58, 3, 1.2, 0.6], [16, 56, 0.6, 1.2, 3]]:
		_box(Vector3(spec[0], spec[3] * 0.5, spec[1]), Vector3(spec[2], spec[3], spec[4]), block)

	# 올라타기: 2m 단, 그 위의 4m 단, 완만한 경사로
	_box(Vector3(-22, 1.0, 34), Vector3(10, 2, 10), block)
	_box(Vector3(-25, 3.0, 37), Vector3(4, 2, 4), block)
	_box(Vector3(-13.5, 0.95, 34), Vector3(8, 0.3, 4), block, Vector3(0, 0, -14.5))

	# 매달리기: 3.5m 단. 뛰어서 올라타기로는 닿지 않고, 턱을 붙잡아야 오른다
	_box(Vector3(-22, 1.75, 50), Vector3(6, 3.5, 6), block)

	# 벽 달리기: 긴 벽 둘 사이의 통로(폭 5m)와 건너뛰는 간격
	_box(Vector3(20, 2.5, 30), Vector3(0.6, 5, 16), wall)
	_box(Vector3(25.6, 2.5, 30), Vector3(0.6, 5, 16), wall)
	# 벽 차기: 좁은 굴뚝(폭 2.2m)을 번갈아 차고 오르면 위 발판에 닿는다
	_box(Vector3(21.5, 3.5, 50), Vector3(0.6, 7, 5), wall)
	_box(Vector3(24.3, 3.5, 50), Vector3(0.6, 7, 5), wall)
	_box(Vector3(27.5, 5.85, 50), Vector3(5, 0.3, 6), block)

	# 보급 상자(구역 밖, 시작 지점 옆)
	var crate := _box(crate_position + Vector3(0, 0.4, 0), Vector3(1.0, 0.8, 0.8), Color(0.3, 0.6, 0.4))
	var label := Label3D.new()
	label.text = "보급"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position.y = 0.9
	label.pixel_size = 0.005
	label.font_size = 40
	label.outline_size = 10
	crate.add_child(label)

	for x: float in [-22.0, -8.0, 8.0, 22.0]:
		spawn_points.append(Vector3(x, 0.1, 70.0))


## 길찾기 메시를 굽는다(호스트만). 구역 안의 지형만 대상으로 한다.
func bake() -> RID:
	var nav := NavigationMesh.new()
	nav.cell_size = 0.25
	nav.cell_height = 0.25
	nav.agent_radius = 0.5
	nav.agent_height = 1.5
	nav.agent_max_climb = 0.25
	nav.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.filter_baking_aabb = AABB(
		Vector3(BOUNDS.position.x - 1.0, -1.0, BOUNDS.position.y - 1.0),
		Vector3(BOUNDS.size.x + 2.0, 8.0, BOUNDS.size.y + 2.0))
	navigation_mesh = nav
	bake_navigation_mesh(false)
	return get_navigation_map()


func contains(pos: Vector3) -> bool:
	return BOUNDS.has_point(Vector2(pos.x, pos.z))


func _box(pos: Vector3, size: Vector3, color: Color, rot_deg: Vector3 = Vector3.ZERO) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.rotation_degrees = rot_deg
	var shape := BoxShape3D.new()
	shape.size = size
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = GRID_SHADER
	mat.set_shader_parameter(&"base_color", color)
	mat.set_shader_parameter(&"line_color", color.darkened(0.3))
	mi.material_override = mat
	body.add_child(mi)
	add_child(body)
	return body
