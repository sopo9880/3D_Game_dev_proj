class_name EnemyDef
extends RefCounted
## 적 정의. data/enemies.json 한 항목.

var id: StringName
var index: int = 0
var display_name: String
var kind: StringName = &"melee"
var hp: float = 50.0
var speed: float = 4.0
var aggro_range: float = 40.0
var attack_damage: float = 10.0
var attack_range: float = 2.0
var attack_windup: float = 0.3
var attack_interval: float = 1.0
var keep_min: float = 0.0
var keep_max: float = 0.0
var projectile_speed: float = 18.0
# 우두머리 전용
var charge_speed: float = 17.0
var charge_time: float = 1.4
var stun_time: float = 2.0
var barrage_damage: float = 25.0
var barrage_radius: float = 3.0
var barrage_delay: float = 1.2
var summon_count: float = 3.0
var summon_type: StringName = &"crawler"
var ring_count: float = 0.0        ## 0보다 크면 포격 대신 번갈아 고리 폭발을 쓴다
var ring_radius: float = 6.0
# 포탑 전용
var burst_count: float = 1.0
var burst_gap: float = 0.15
var radius: float = 0.4
var height: float = 1.2
var head_radius: float = 0.2
var loot: Array = []
var tint: Array = []                ## [r, g, b]. 비어 있으면 종류별 기본 색


static func load_all(path: String) -> Array[EnemyDef]:
	var out: Array[EnemyDef] = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Array:
		push_error("적 데이터를 읽을 수 없음: %s" % path)
		return out
	for row: Dictionary in parsed:
		var d := EnemyDef.new()
		d.id = StringName(str(row.get("id", "")))
		d.display_name = str(row.get("name", d.id))
		d.index = out.size()
		for key: String in row:
			if key in ["id", "name"]:
				continue
			var cur: Variant = d.get(key)
			match typeof(cur):
				TYPE_FLOAT: d.set(key, float(row[key]))
				TYPE_STRING_NAME: d.set(key, StringName(str(row[key])))
				TYPE_ARRAY: d.set(key, row[key])
				_: push_warning("적 %s: 모르는 항목 '%s'" % [d.id, key])
		out.append(d)
	return out
