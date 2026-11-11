class_name ReferenceLine
extends RefCounted
## 기준 생산 라인의 설계도: 채굴기 1 → 분배기 → 제련기 2 → 합류기 → 저장소, 발전기 1.
## 테스트, 벤치마크, 개발용 샌드박스가 함께 쓴다. 차지하는 범위: x -2..10, z 5..22.

const NODE_CELL := Vector3i(1, 0, 21)   ## 채굴기 밑의 광맥 칸 (원점 기준)
const GENERATOR_CELL := Vector3i(8, 0, 20)

## [구조물 ID, 칸] 목록 (원점 기준).
const MACHINES: Array[Array] = [
	[&"miner", Vector3i(0, 0, 20)],
	[&"junction", Vector3i(1, 0, 17)],
	[&"smelter", Vector3i(-2, 0, 13)],
	[&"smelter", Vector3i(4, 0, 13)],
	[&"junction", Vector3i(1, 0, 10)],
	[&"storage", Vector3i(1, 0, 5)],
	[&"bio_generator", GENERATOR_CELL],
]
## 벨트 경로 (x, z 쌍, 상류에서 하류 순서).
const BELTS: Array[Array] = [
	[[1, 19], [1, 18]],
	[[0, 17], [-1, 17], [-2, 17], [-2, 16]],
	[[2, 17], [3, 17], [4, 17], [4, 16]],
	[[-2, 12], [-2, 11], [-2, 10], [-1, 10], [0, 10]],
	[[4, 12], [4, 11], [4, 10], [3, 10], [2, 10]],
	[[1, 9], [1, 8], [1, 7]],
]


static func belt_path(origin: Vector3i, index: int) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for p: Array in BELTS[index]:
		out.append(origin + Vector3i(p[0], 0, p[1]))
	return out
