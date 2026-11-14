class_name TechDef
extends RefCounted
## 연구 항목. data/techs.json 한 항목. 연구하면 구조물이나 레시피가 월드 전체에 열린다.

var id: StringName
var index: int = -1
var display_name: String
var cost_items: PackedInt32Array = []
var cost_counts: PackedInt32Array = []
var requires: int = -1                 ## 먼저 끝내야 하는 연구의 인덱스. 없으면 -1
var unlocks: Array[StringName] = []    ## 구조물 ID 또는 레시피 ID
