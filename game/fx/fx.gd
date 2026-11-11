class_name Fx
extends Node3D
## 임시 시각 효과: 예광탄, 착탄 불꽃, 탄흔, 피해 숫자.

const MAX_MARKS := 80

var _tracer_mat: StandardMaterial3D
var _spark_mat: StandardMaterial3D
var _mark_mat: StandardMaterial3D
var _marks: Array[MeshInstance3D] = []


func _ready() -> void:
	_tracer_mat = _unshaded(Color(1.0, 0.85, 0.45))
	_spark_mat = _unshaded(Color(1.0, 0.75, 0.3))
	_mark_mat = StandardMaterial3D.new()
	_mark_mat.albedo_color = Color(0.05, 0.05, 0.05)


func tracer(from: Vector3, to: Vector3) -> void:
	var length := from.distance_to(to)
	if length < 1.5:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.012, 0.012, length)
	var node := _mesh_node(mesh, _tracer_mat)
	node.look_at_from_position((from + to) * 0.5, to, _up_for(to - from))
	_fade_and_free(node, 0.07)


func impact(pos: Vector3, normal: Vector3, on_target: bool) -> void:
	var sparks := CPUParticles3D.new()
	sparks.one_shot = true
	sparks.emitting = true
	sparks.amount = 6 if on_target else 10
	sparks.lifetime = 0.25
	sparks.explosiveness = 1.0
	sparks.direction = normal
	sparks.spread = 50.0
	sparks.initial_velocity_min = 2.0
	sparks.initial_velocity_max = 6.0
	sparks.gravity = Vector3(0, -12, 0)
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 0.03
	sparks.mesh = mesh
	sparks.material_override = _spark_mat
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sparks)
	sparks.global_position = pos + normal * 0.02
	get_tree().create_timer(0.6).timeout.connect(sparks.queue_free)
	if on_target:
		return
	var disc := CylinderMesh.new()
	disc.top_radius = 0.035
	disc.bottom_radius = 0.035
	disc.height = 0.004
	var mark := _mesh_node(disc, _mark_mat)
	mark.global_position = pos + normal * 0.003
	if absf(normal.dot(Vector3.UP)) < 0.99:
		mark.look_at(pos + normal, Vector3.UP)
		mark.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	_marks.append(mark)
	if _marks.size() > MAX_MARKS:
		_marks.pop_front().queue_free()


func damage_number(pos: Vector3, amount: float, head: bool, killed: bool) -> void:
	var label := Label3D.new()
	label.text = str(roundi(amount))
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = true
	label.pixel_size = 0.0009 if not head else 0.0012
	label.font_size = 48
	label.outline_size = 12
	label.modulate = Color(1.0, 0.3, 0.25) if killed else (Color(1.0, 0.85, 0.2) if head else Color.WHITE)
	add_child(label)
	label.global_position = pos + Vector3(randf_range(-0.15, 0.15), 0.1, randf_range(-0.15, 0.15))
	var tw := label.create_tween().set_parallel()
	tw.tween_property(label, "global_position", label.global_position + Vector3(0, 0.7, 0), 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(label, "modulate:a", 0.0, 0.6).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(label.queue_free)


func _mesh_node(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func _fade_and_free(node: MeshInstance3D, time: float) -> void:
	var tw := node.create_tween()
	tw.tween_property(node, "transparency", 1.0, time)
	tw.tween_callback(node.queue_free)


func _unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	return m


func _up_for(dir: Vector3) -> Vector3:
	return Vector3.RIGHT if absf(dir.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
