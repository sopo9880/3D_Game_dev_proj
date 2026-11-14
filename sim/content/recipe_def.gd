class_name RecipeDef
extends RefCounted
## 레시피 정의. 시간은 틱(10틱 = 1초), 수량은 정수.

var id: StringName
var in_items: PackedInt32Array = []   ## 아이템 인덱스
var in_counts: PackedInt32Array = []
var out_item: int = -1
var out_count: int = 1
var ticks: int = 10
var machines: Array[StringName] = []
var unlocked_by_default: bool = true
var unlock_tech: int = -1   ## 이 연구가 끝나야 만들 수 있다. -1이면 처음부터 가능
