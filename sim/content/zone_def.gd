class_name ZoneDef
extends RefCounted
## 복원할 수 있는 구역의 정의. data/zones.json 한 항목.

var id: StringName
var index: int = -1
var display_name: String
var capsule_item: int = -1
var capsule_points: int = 10
var beacon_site: Vector3i = Vector3i.ZERO      ## 복원 비콘을 세울 수 있는 유일한 자리(원점 칸)
var requires: int = -1                         ## 먼저 복원해야 하는 구역의 인덱스. 없으면 -1
var reward_items: PackedInt32Array = []        ## 복원이 끝나면 모든 플레이어가 받는 것
var reward_counts: PackedInt32Array = []
var unlock_zone: PackedInt32Array = []         ## 복원이 끝나면 열리는 건축 구역 [x, z, 폭, 깊이, 지면 높이]
