class_name WeaponDef
extends RefCounted
## 무기 정의. data/weapons.json 한 항목. 조정 패널이 실행 중에 값을 바꿀 수 있다.

var id: StringName
var display_name: String
var slot: int = 1
var ammo_item: StringName = &""    ## 재장전할 때 소지품에서 쓰는 탄약. 비어 있으면 탄약이 필요 없다

var damage: float = 10.0
var pellets: int = 1
var rpm: float = 600.0
var auto: bool = true
var mag: int = 30
var reload_time: float = 2.0
var reload_per_shell: bool = false
var infinite_ammo: bool = false
var head_mult: float = 1.5

var falloff_start: float = 20.0
var falloff_end: float = 50.0
var falloff_min: float = 0.6

var spread_hip: float = 1.0       ## 도. 원뿔 반각
var spread_ads: float = 0.2
var spread_move: float = 1.0      ## 최고 속도로 움직일 때 더해지는 값
var spread_air: float = 3.0
var bloom_per_shot: float = 0.2
var bloom_max: float = 2.0
var bloom_recover: float = 5.0    ## 초당 도

var recoil_v: float = 0.5         ## 한 발당 위로 튀는 각도(도)
var recoil_v_cap: float = 8.0     ## 누적 수직 반동이 이 각도를 넘으면 더는 거의 오르지 않는다
var recoil_h: Array[float] = [0.0]  ## 연사 순서대로 도는 좌우 패턴(도)
var recoil_h_rand: float = 0.1
var recoil_snap: float = 30.0     ## 반동이 화면에 반영되는 빠르기
var recoil_recover: float = 7.0   ## 조준점이 되돌아오는 빠르기
var recoil_reset_time: float = 0.3
var ads_recoil_mult: float = 0.75

var ads_fov: float = 55.0
var ads_time: float = 0.15
var kick_back: float = 0.04       ## 총 모형이 뒤로 밀리는 거리(m)
var kick_up: float = 3.0          ## 총 모형이 들리는 각도(도)
var shake: float = 0.2

## 조정 패널에 노출할 값: [속성, 최소, 최대, 단계, 표시 이름]
const TUNABLES: Array[Array] = [
	["damage", 1, 100, 1, "피해"],
	["rpm", 30, 1200, 10, "연사 (분당)"],
	["mag", 1, 100, 1, "탄창"],
	["reload_time", 0.2, 4.0, 0.05, "재장전 (초)"],
	["head_mult", 1.0, 3.0, 0.05, "머리 배율"],
	["spread_hip", 0.0, 8.0, 0.05, "기본 탄퍼짐 (도)"],
	["spread_ads", 0.0, 5.0, 0.05, "조준 탄퍼짐"],
	["spread_move", 0.0, 5.0, 0.05, "이동 탄퍼짐"],
	["bloom_per_shot", 0.0, 2.0, 0.01, "연사 시 퍼짐 증가"],
	["bloom_max", 0.0, 8.0, 0.1, "퍼짐 증가 한도"],
	["bloom_recover", 0.5, 20.0, 0.5, "퍼짐 회복"],
	["recoil_v", 0.0, 10.0, 0.05, "수직 반동 (도)"],
	["recoil_v_cap", 0.0, 30.0, 0.5, "수직 반동 한도 (도)"],
	["recoil_h_rand", 0.0, 2.0, 0.01, "수평 반동 무작위"],
	["recoil_snap", 5, 60, 1, "반동 반응 속도"],
	["recoil_recover", 0, 25, 0.5, "반동 회복 속도"],
	["ads_recoil_mult", 0.1, 1.5, 0.05, "조준 시 반동 배율"],
	["ads_fov", 30, 85, 1, "조준 시야각"],
	["ads_time", 0.03, 0.5, 0.01, "조준 전환 (초)"],
	["kick_back", 0.0, 0.3, 0.005, "총 모형 밀림"],
	["kick_up", 0.0, 25.0, 0.5, "총 모형 들림"],
	["shake", 0.0, 2.0, 0.05, "화면 흔들림"],
]


static func load_all(path: String) -> Array[WeaponDef]:
	var out: Array[WeaponDef] = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Array:
		push_error("무기 데이터를 읽을 수 없음: %s" % path)
		return out
	for row: Dictionary in parsed:
		out.append(from_dict(row))
	out.sort_custom(func(a: WeaponDef, b: WeaponDef) -> bool: return a.slot < b.slot)
	return out


static func from_dict(row: Dictionary) -> WeaponDef:
	var d := WeaponDef.new()
	d.id = StringName(str(row.get("id", "")))
	d.display_name = str(row.get("name", d.id))
	for key: String in row:
		if key in ["id", "name"]:
			continue
		if key == "recoil_h":
			d.recoil_h.clear()
			for v: Variant in row[key]:
				d.recoil_h.append(float(v))
			continue
		var current: Variant = d.get(key)
		match typeof(current):
			TYPE_INT: d.set(key, int(row[key]))
			TYPE_FLOAT: d.set(key, float(row[key]))
			TYPE_BOOL: d.set(key, bool(row[key]))
			TYPE_STRING_NAME: d.set(key, StringName(str(row[key])))
			_: push_warning("무기 %s: 모르는 항목 '%s'" % [d.id, key])
	return d


## 조정한 값을 data/weapons.json 형식으로 되돌린다.
func to_dict() -> Dictionary:
	var out := {"id": String(id), "name": display_name}
	for p: Dictionary in get_script().get_script_property_list():
		var key: String = p["name"]
		if key in ["id", "display_name"] or not (p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var v: Variant = get(key)
		out[key] = snappedf(v, 0.001) if v is float else (String(v) if v is StringName else v)
	return out
