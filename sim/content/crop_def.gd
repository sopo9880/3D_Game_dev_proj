class_name CropDef
extends RefCounted
## 작물 정의. data/crops.json 한 항목.

var id: StringName
var index: int = -1
var display_name: String
var seed_item: int = -1
var product_item: int = -1
var grow_ticks: int = 1200
var stages: int = 4
var yield_count: int = 1
var seed_return: int = 1
var bonus_seed_percent: int = 0
