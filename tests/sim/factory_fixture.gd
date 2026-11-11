class_name FactoryFixture
extends RefCounted
## 테스트와 벤치마크용: ReferenceLine 설계도를 시뮬레이션에 직접 짓는다.

static func v(x: int, z: int) -> Vector3i:
	return Vector3i(x, 0, z)


static func path(o: Vector3i, pts: Array) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for p: Array in pts:
		out.append(o + Vector3i(p[0], 0, p[1]))
	return out


## 기준 라인을 o 위치에 짓고 주요 구조물을 돌려준다.
static func build_line(w: SimWorld, o: Vector3i = Vector3i.ZERO, fuel: int = 10) -> Dictionary:
	w.add_node(o + ReferenceLine.NODE_CELL, &"iron_ore")
	var keys := ["miner", "split", "smelter_a", "smelter_b", "merge", "storage", "gen"]
	var r := {}
	for i in ReferenceLine.MACHINES.size():
		r[keys[i]] = w.place(ReferenceLine.MACHINES[i][0], o + (ReferenceLine.MACHINES[i][1] as Vector3i))
	var belts: Array = []
	for i in ReferenceLine.BELTS.size():
		belts.append(w.place_belt(&"belt", ReferenceLine.belt_path(o, i)))
	r["belts"] = belts
	if fuel > 0:
		w.insert((r["gen"] as SimStructure).id, &"biofuel", fuel)
	return r


static func run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.tick()
