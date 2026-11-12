class_name StructureDef
extends RefCounted
## 구조물 정의. data/structures.json 한 항목.

enum Kind { NONE, CRAFTER, BELT, JUNCTION, STORAGE, GENERATOR, POWER_POLE, FLOOR, WALL, STAIRS, PLOT, WORKBENCH, DECOR, BEACON }
enum PortIO { IN, OUT, ANY }

const KIND_NAMES: Dictionary[String, int] = {
	"none": Kind.NONE, "crafter": Kind.CRAFTER, "belt": Kind.BELT, "junction": Kind.JUNCTION,
	"storage": Kind.STORAGE, "generator": Kind.GENERATOR, "power_pole": Kind.POWER_POLE,
	"floor": Kind.FLOOR, "wall": Kind.WALL, "stairs": Kind.STAIRS, "plot": Kind.PLOT,
	"workbench": Kind.WORKBENCH, "decor": Kind.DECOR, "beacon": Kind.BEACON,
}
const DIR_NAMES: Dictionary[String, int] = {"n": 0, "e": 1, "s": 2, "w": 3}
const IO_NAMES: Dictionary[String, int] = {"in": PortIO.IN, "out": PortIO.OUT, "any": PortIO.ANY}

var id: StringName
var tab: StringName
var kind: int = Kind.NONE
var footprint: Vector3i = Vector3i.ONE
var cost_items: PackedInt32Array = []
var cost_counts: PackedInt32Array = []
var port_cells: Array[Vector3i] = []
var port_dirs: PackedInt32Array = []
var port_ios: PackedInt32Array = []
var power_use: int = 0
var power_gen: int = 0
var power_radius: int = 0
var params: Dictionary = {}
## 이 설비에서 가능한 레시피(ContentDB가 채운다).
var recipes: Array[RecipeDef] = []
## 발전기: 연료 아이템 인덱스 → 연소 틱.
var fuels: Dictionary[int, int] = {}
