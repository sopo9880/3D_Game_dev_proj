class_name Gun
extends RefCounted
## 무기 한 자루의 실행 상태. 씬과 무관한 규칙만 담는다
## (연사 간격, 탄약, 재장전, 탄퍼짐, 반동 패턴). 나중에 호스트 검증도 이 규칙을 쓴다.

signal reload_started
signal reload_step       ## 한 발씩 장전하는 무기에서 한 발이 들어갈 때
signal reload_finished

var def: WeaponDef
var mag: int
var cooldown: float = 0.0
var reload_left: float = 0.0
var bloom: float = 0.0
var burst_index: int = 0
var since_shot: float = 99.0


func _init(weapon: WeaponDef) -> void:
	def = weapon
	mag = def.mag


func is_reloading() -> bool:
	return reload_left > 0.0


func shot_interval() -> float:
	return 60.0 / maxf(def.rpm, 1.0)


func update(delta: float) -> void:
	cooldown = maxf(cooldown - delta, -shot_interval())
	since_shot += delta
	bloom = move_toward(bloom, 0.0, def.bloom_recover * delta)
	if since_shot > def.recoil_reset_time:
		burst_index = 0
	if reload_left > 0.0:
		reload_left -= delta
		if reload_left <= 0.0:
			if def.reload_per_shell:
				mag = mini(mag + 1, def.mag)
				reload_step.emit()
				if mag < def.mag:
					reload_left += def.reload_time
					return
			else:
				mag = def.mag
			reload_left = 0.0
			reload_finished.emit()


func can_fire() -> bool:
	if cooldown > 0.0 or mag <= 0:
		return false
	# 한 발씩 장전하는 무기는 장전 중에도 쏠 수 있다(장전이 끊긴다).
	return not is_reloading() or (def.reload_per_shell and mag > 0)


## 한 발 쏜다. 탄약과 간격을 처리하고, 이번 발의 반동(x = 좌우, y = 위, 도)을 돌려준다.
func fire(ads: bool) -> Vector2:
	reload_left = 0.0
	mag -= 1
	# 연사 중에는 남은 음수 쿨다운을 이어 받아 프레임 속도와 무관하게 연사 속도를 지킨다.
	var carry := cooldown if since_shot < shot_interval() * 1.5 else 0.0
	cooldown = shot_interval() + carry
	var pattern := def.recoil_h[burst_index % def.recoil_h.size()] if not def.recoil_h.is_empty() else 0.0
	var kick := Vector2(pattern + randf_range(-def.recoil_h_rand, def.recoil_h_rand), def.recoil_v)
	# 연사가 길어지면 위로는 덜 튀고 좌우 패턴이 남는다.
	if burst_index * def.recoil_v > def.recoil_v_cap:
		kick.y *= 0.15
	if ads:
		kick *= def.ads_recoil_mult
	burst_index += 1
	since_shot = 0.0
	bloom = minf(bloom + def.bloom_per_shot, def.bloom_max)
	return kick


func start_reload() -> bool:
	if is_reloading() or mag >= def.mag:
		return false
	reload_left = def.reload_time
	reload_started.emit()
	return true


## 현재 탄퍼짐(도). move_frac은 0..1(최고 속도 대비), air는 공중 여부.
func spread(ads: bool, move_frac: float, air: bool) -> float:
	var s := def.spread_ads if ads else def.spread_hip
	s += bloom * (0.5 if ads else 1.0)
	s += def.spread_move * clampf(move_frac, 0.0, 1.0) * (0.4 if ads else 1.0)
	if air:
		s += def.spread_air
	return s


## 거리별 피해 배율.
func falloff(distance: float) -> float:
	if distance <= def.falloff_start:
		return 1.0
	if distance >= def.falloff_end:
		return def.falloff_min
	return lerpf(1.0, def.falloff_min, (distance - def.falloff_start) / (def.falloff_end - def.falloff_start))
