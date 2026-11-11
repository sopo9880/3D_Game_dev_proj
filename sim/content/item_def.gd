class_name ItemDef
extends RefCounted
## 아이템 정의. data/items.json 한 항목.

var id: StringName
var index: int = -1  ## 시뮬레이션 내부용 정수 인덱스. 저장하지 않는다.
var display_name: String
var stack_size: int = 100
var category: StringName
