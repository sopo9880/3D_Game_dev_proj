class_name FactoryFixture
extends RefCounted
## 테스트와 벤치마크가 함께 쓰는 기준 생산 라인.
## 채굴기 1 → 분배기 → 제련기 2 → 합류기 → 저장소, 발전기 1.
## 차지하는 범위: x -2..10, z 5..22.

static func v(x: int, z: int) -> Vector3i:
	return Vector3i(x, 0, z)


static func path(o: Vector3i, pts: Array) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for p: Array in pts:
		out.append(o + Vector3i(p[0], 0, p[1]))
	return out


## 기준 라인을 o 위치에 짓고 주요 구조물을 돌려준다.
static func build_line(w: SimWorld, o: Vector3i = Vector3i.ZERO, fuel: int = 10) -> Dictionary:
	w.add_node(o + v(1, 21), &"iron_ore")
	var r := {}
	r["miner"] = w.place(&"miner", o + v(0, 20))
	r["split"] = w.place(&"junction", o + v(1, 17))
	r["smelter_a"] = w.place(&"smelter", o + v(-2, 13))
	r["smelter_b"] = w.place(&"smelter", o + v(4, 13))
	r["merge"] = w.place(&"junction", o + v(1, 10))
	r["storage"] = w.place(&"storage", o + v(1, 5))
	r["gen"] = w.place(&"bio_generator", o + v(8, 20))
	r["belts"] = [
		w.place_belt(&"belt", path(o, [[1, 19], [1, 18]])),
		w.place_belt(&"belt", path(o, [[0, 17], [-1, 17], [-2, 17], [-2, 16]])),
		w.place_belt(&"belt", path(o, [[2, 17], [3, 17], [4, 17], [4, 16]])),
		w.place_belt(&"belt", path(o, [[-2, 12], [-2, 11], [-2, 10], [-1, 10], [0, 10]])),
		w.place_belt(&"belt", path(o, [[4, 12], [4, 11], [4, 10], [3, 10], [2, 10]])),
		w.place_belt(&"belt", path(o, [[1, 9], [1, 8], [1, 7]])),
	]
	if fuel > 0:
		w.insert((r["gen"] as SimStructure).id, &"biofuel", fuel)
	return r


static func run(w: SimWorld, ticks: int) -> void:
	for i in ticks:
		w.tick()
