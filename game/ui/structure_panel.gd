class_name StructurePanel
extends PanelContainer
## 구조물과 상호작용하는 패널(E). 설비의 상태를 보여 주고 넣기·꺼내기·레시피·제작·밭 관리를 한다.
## 버튼은 요청만 보낸다. 실제 변화는 호스트가 승인한 뒤 화면에 반영된다.

const STATE_NAMES: Array[String] = ["대기", "가동", "재료 부족", "출력 막힘", "전력 부족", "레시피 없음"]

var structure_id: int = 0
var _title: Label
var _info: Label
var _buttons: VBoxContainer
var _signature: String = ""


func _ready() -> void:
	visible = false
	custom_minimum_size = Vector2(460, 0)
	set_anchors_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override(&"font_size", 22)
	box.add_child(_title)
	_info = Label.new()
	_info.add_theme_font_size_override(&"font_size", 16)
	box.add_child(_info)
	_buttons = VBoxContainer.new()
	box.add_child(_buttons)
	var hint := Label.new()
	hint.text = "E 또는 Esc로 닫기"
	hint.modulate.a = 0.6
	hint.add_theme_font_size_override(&"font_size", 13)
	box.add_child(hint)


func open(id: int) -> bool:
	var s: SimStructure = World.sim.structures.get(id)
	if s == null or not s.kind in [StructureDef.Kind.CRAFTER, StructureDef.Kind.STORAGE, StructureDef.Kind.GENERATOR,
			StructureDef.Kind.PLOT, StructureDef.Kind.WORKBENCH, StructureDef.Kind.BEACON]:
		return false
	structure_id = id
	_signature = ""
	visible = true
	_refresh()
	return true


func close() -> void:
	visible = false
	structure_id = 0


func _process(_delta: float) -> void:
	if visible and Engine.get_process_frames() % 6 == 0:
		_refresh()


## 패널의 버튼이 하는 일들. 화면 없이도 부를 수 있다.
func act(op: String, args: Array) -> void:
	World.request(op, args)


func _refresh() -> void:
	var s: SimStructure = World.sim.structures.get(structure_id) if World.sim != null else null
	if s == null:
		close()
		return
	var db := Registry.db
	var key := World.my_key()
	var lines: PackedStringArray = []
	var buttons: Array = []   # [글자, 작업, 인자, 가능 여부]
	_title.text = BuildMode._display_name(s.def)
	match s.kind:
		StructureDef.Kind.CRAFTER:
			lines.append("상태: %s" % STATE_NAMES[s.state])
			if s.def.power_use > 0:
				lines.append("전력: %s" % ("연결 안 됨" if s.grid == null else "충족률 %d%%" % (s.grid.ratio / 10)))
			if s.recipe != null:
				var r := s.recipe
				for i in r.in_items.size():
					var item_def := db.item_def(r.in_items[i])
					lines.append("재료  %s  %d (한 번에 %d)" % [item_def.display_name, s.in_counts[i], r.in_counts[i]])
					var have := World.sim.inv_count(key, r.in_items[i])
					buttons.append(["%s 넣기 (소지 %d)" % [item_def.display_name, have], "insert",
						[s.id, String(item_def.id), 9999], have > 0])
				var out_def := db.item_def(r.out_item)
				lines.append("생산  %s  %d   · 누적 %d" % [out_def.display_name, s.out_count, s.produced_total])
				buttons.append(["%s 꺼내기" % out_def.display_name, "take", [s.id, String(out_def.id), 9999], s.out_count > 0])
			if s.def.recipes.size() > 1 and not s.def.params.get("needs_node", false):
				for r in s.def.recipes:
					buttons.append(["레시피: %s%s" % [db.item_def(r.out_item).display_name, "  ✓" if r == s.recipe else ""],
						"recipe", [s.id, String(r.id)], r != s.recipe])
		StructureDef.Kind.STORAGE:
			lines.append("칸 %d / %d" % [s.store_slots_used, int(s.def.params.get("slots", 0))])
			for item: int in s.store:
				var item_def := db.item_def(item)
				buttons.append(["꺼내기: %s %d" % [item_def.display_name, s.store[item]], "take", [s.id, String(item_def.id), 99999], true])
			var inv: Dictionary = World.my_inventory()
			for item: int in inv:
				var item_def := db.item_def(item)
				buttons.append(["넣기: %s %d" % [item_def.display_name, int(inv[item])], "insert", [s.id, String(item_def.id), 99999], true])
		StructureDef.Kind.GENERATOR:
			lines.append("연료 %d%s" % [s.fuel_count, "  · 연소 중 (%d초 남음)" % (s.burn_left / 10) if s.burn_left > 0 else ""])
			if s.grid != null:
				lines.append("전력망: 공급 %d / 수요 %d" % [s.grid.supply, s.grid.demand])
			for fuel: int in s.def.fuels:
				var item_def := db.item_def(fuel)
				var have := World.sim.inv_count(key, fuel)
				buttons.append(["%s 넣기 (소지 %d)" % [item_def.display_name, have], "insert", [s.id, String(item_def.id), 9999], have > 0])
		StructureDef.Kind.PLOT:
			var state := World.sim.plot_state(s)
			if state == "empty":
				lines.append("비어 있음")
				for crop in db.crops:
					var seed_def := db.item_def(crop.seed_item)
					var have := World.sim.inv_count(key, crop.seed_item)
					buttons.append(["%s 심기 (소지 %d)" % [seed_def.display_name, have], "plant", [s.id, String(seed_def.id)], have > 0])
			else:
				var crop := db.crops[s.crop]
				lines.append("%s  %d%%%s" % [crop.display_name, mini(s.growth * 100 / crop.grow_ticks, 100), "  · 물 줌" if s.watered else ""])
				buttons.append(["물 주기", "water", [s.id], state == "growing" and not s.watered])
				buttons.append(["수확", "harvest", [s.id], state == "ready"])
		StructureDef.Kind.BEACON:
			var zone_def := db.zones[s.zone]
			var progress := World.sim.zone_progress(s.zone)
			lines.append("%s 복원 %d%%" % [zone_def.display_name, progress])
			lines.append("정화 캡슐 하나에 %d%%. 벨트로도 넣을 수 있다(남쪽 포트)." % zone_def.capsule_points)
			var capsule := db.item_def(zone_def.capsule_item)
			var have := World.sim.inv_count(key, zone_def.capsule_item)
			buttons.append(["%s 넣기 (소지 %d)" % [capsule.display_name, have], "insert", [s.id, String(capsule.id), 9999],
				have > 0 and progress < 100])
		StructureDef.Kind.WORKBENCH:
			lines.append("손으로 만든다. 재료는 소지품에서 쓴다.")
			for r in s.def.recipes:
				var needs: PackedStringArray = []
				var can := true
				for i in r.in_items.size():
					var have := World.sim.inv_count(key, r.in_items[i])
					needs.append("%s %d/%d" % [db.item_def(r.in_items[i]).display_name, have, r.in_counts[i]])
					can = can and have >= r.in_counts[i]
				var label := "%s ×%d   ← %s" % [db.item_def(r.out_item).display_name, r.out_count, ", ".join(needs)]
				buttons.append([label, "craft", [String(r.id), 1], can])
				buttons.append(["      같은 것 5번", "craft", [String(r.id), 5], can])
	_info.text = "\n".join(lines)

	# 버튼 구성이 바뀌었을 때만 다시 만든다(누르는 도중에 버튼이 사라지지 않게).
	var signature := ""
	for b: Array in buttons:
		signature += "%s|%s|%s\n" % [b[0], b[1], b[3]]
	if signature == _signature:
		return
	_signature = signature
	for c in _buttons.get_children():
		c.queue_free()
	for b: Array in buttons:
		var button := Button.new()
		button.text = b[0]
		button.disabled = not b[3]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.focus_mode = Control.FOCUS_NONE
		var op: String = b[1]
		var args: Array = b[2]
		button.pressed.connect(func() -> void: act(op, args))
		_buttons.add_child(button)
