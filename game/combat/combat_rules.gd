class_name CombatRules
extends RefCounted
## 전투 규칙 중 씬과 무관한 계산. 호스트 검증과 단위 테스트가 함께 쓴다.

const MAX_HP := 100.0
const REGEN_DELAY := 5.0        ## 마지막 피해 뒤 회복이 시작되기까지(초)
const REGEN_PER_SECOND := 10.0
const DOWN_SECONDS := 30.0      ## 쓰러진 뒤 동료가 일으킬 수 있는 시간
const SOLO_RESPAWN_SECONDS := 3.0
const REVIVE_RANGE := 3.0
const REVIVE_HP := 30.0
const MAX_HIT_DISTANCE := 150.0
const MELEE_DAMAGE := 45.0
const MELEE_INTERVAL := 0.6      ## 근접 공격 사이의 최소 간격(초)
const MELEE_MAX_DISTANCE := 4.5  ## 호스트가 인정하는 최대 거리(지연을 감안한 여유 포함)
const MELEE_MAX_TARGETS := 3
const GRENADE_MAX := 3
const GRENADE_RADIUS := 5.0
const GRENADE_DAMAGE := 120.0
const GRENADE_MAX_SPEED := 26.0


## 협동 보정: 그 구역에 있는 인원 기준(Blueprint/02 전투).
static func scaled_hp(base_hp: float, players_in_zone: int) -> float:
	return base_hp * (1.0 + 0.5 * maxi(players_in_zone - 1, 0))


static func falloff(def: WeaponDef, distance: float) -> float:
	if distance <= def.falloff_start:
		return 1.0
	if distance >= def.falloff_end:
		return def.falloff_min
	return lerpf(1.0, def.falloff_min, (distance - def.falloff_start) / (def.falloff_end - def.falloff_start))


static func hit_damage(def: WeaponDef, distance: float, head: bool) -> float:
	return def.damage * falloff(def, distance) * (def.head_mult if head else 1.0)


## 클라이언트가 보고한 한 번의 사격(탄환 묶음)을 받아들일지 판단한다. 문제가 없으면 빈 문자열.
## since_last: 그 플레이어의 직전 사격 보고 뒤 지난 시간(초).
static func check_shot(def: WeaponDef, pellet_count: int, since_last: float) -> String:
	if def == null:
		return "unknown_weapon"
	if pellet_count <= 0 or pellet_count > def.pellets:
		return "too_many_pellets"
	# 지연과 프레임 오차를 감안해 연사 간격의 60%까지는 받아 준다.
	if since_last < 60.0 / maxf(def.rpm, 1.0) * 0.6:
		return "too_fast"
	return ""


## 근접 공격 보고를 받아들일지. 문제가 없으면 빈 문자열.
static func check_melee(target_count: int, since_last: float) -> String:
	if target_count <= 0 or target_count > MELEE_MAX_TARGETS:
		return "too_many_targets"
	if since_last < MELEE_INTERVAL * 0.6:
		return "too_fast"
	return ""


static func grenade_damage(distance: float) -> float:
	if distance >= GRENADE_RADIUS:
		return 0.0
	return GRENADE_DAMAGE * (1.0 - distance / GRENADE_RADIUS)


## 전리품 굴림. table: [[아이템, 수량, 확률], ...]. 결과: 아이템 → 수량.
static func roll_loot(table: Array, rng: RandomNumberGenerator) -> Dictionary:
	var out := {}
	for row: Array in table:
		if rng.randf() < float(row[2]):
			var id := str(row[0])
			out[id] = int(out.get(id, 0)) + int(row[1])
	return out
