class_name SaveMigrations
extends RefCounted
## 옛 형식의 저장 데이터를 현재 형식으로 올린다. 형식이 바뀔 때마다 여기에 한 단계를 추가하고,
## 그 전 형식의 샘플을 tests/fixtures/ 에 남겨 불러오기를 테스트한다.

## 시뮬레이션 상태(SimWorld.to_dict)의 형식을 현재(SimWorld.SAVE_FORMAT)까지 올린다.
## 올릴 수 없으면(모르는 형식, 미래 형식) 빈 사전을 돌려준다.
static func migrate_sim(d: Dictionary) -> Dictionary:
	var out := d.duplicate(true)
	var format := int(out.get("format", -1))
	if format < 1 or format > SimWorld.SAVE_FORMAT:
		return {}
	while format < SimWorld.SAVE_FORMAT:
		match format:
			1: out = _sim_1_to_2(out)
			2: out = _sim_2_to_3(out)
			3: out = _sim_3_to_4(out)
			_: return {}
		format = int(out.get("format", -1))
	return out


## 1 → 2 (v0.3.0): 플레이어 소지품이 월드 상태에 들어왔다. 옛 세이브에는 소지품이 없으므로
## 빈 목록으로 시작하고, 접속할 때 시작 지급품을 받는다.
static func _sim_1_to_2(d: Dictionary) -> Dictionary:
	d["inventories"] = []
	d["format"] = 2
	return d


## 2 → 3 (v0.3.1): 건축 가능 구역이 월드 상태에 들어왔다. 옛 세이브는 구역이 없으므로
## 전체가 높이 0의 평지로 취급되어, 지어 둔 것이 전부 그대로 유효하다.
static func _sim_2_to_3(d: Dictionary) -> Dictionary:
	d["zones"] = []
	d["format"] = 3
	return d


## 3 → 4 (v0.4.0): 구역 복원 진행도와 손 채집 대기 시간이 월드 상태에 들어왔다.
## 옛 세이브는 아무 구역도 복원하지 않은 상태로 시작한다.
static func _sim_3_to_4(d: Dictionary) -> Dictionary:
	d["restore"] = []
	d["gather"] = []
	d["format"] = 4
	return d
