extends TestCase

var rifle: WeaponDef
var shotgun: WeaponDef


func before_each() -> void:
	for w in WeaponDef.load_all("res://data/weapons.json"):
		if w.id == &"rifle":
			rifle = w
		elif w.id == &"shotgun":
			shotgun = w


func test_hp_scales_with_players_in_zone() -> void:
	eq(CombatRules.scaled_hp(60.0, 1), 60.0, "1인")
	eq(CombatRules.scaled_hp(60.0, 2), 90.0, "2인")
	eq(CombatRules.scaled_hp(60.0, 8), 270.0, "8인")
	eq(CombatRules.scaled_hp(60.0, 0), 60.0, "0인은 1인처럼")


func test_damage_falloff_and_headshot() -> void:
	eq(CombatRules.hit_damage(rifle, 10.0, false), 12.0, "가까운 몸통")
	eq(CombatRules.hit_damage(rifle, 10.0, true), 18.0, "가까운 머리")
	eq(CombatRules.hit_damage(rifle, 35.0, false), 12.0 * 0.8, "감소 구간 중간")
	eq(CombatRules.hit_damage(rifle, 500.0, false), 12.0 * 0.6, "최소 배율")


func test_shot_validation() -> void:
	eq(CombatRules.check_shot(rifle, 1, 0.1), "", "정상 연사")
	eq(CombatRules.check_shot(rifle, 1, 0.065), "", "지연을 감안한 여유")
	eq(CombatRules.check_shot(rifle, 1, 0.02), "too_fast", "연사 속도 초과")
	eq(CombatRules.check_shot(rifle, 2, 1.0), "too_many_pellets", "소총이 두 발을 보고")
	eq(CombatRules.check_shot(shotgun, 10, 1.0), "", "샷건 10발")
	eq(CombatRules.check_shot(shotgun, 11, 1.0), "too_many_pellets", "샷건 11발")
	eq(CombatRules.check_shot(null, 1, 1.0), "unknown_weapon", "모르는 무기")
	eq(CombatRules.check_shot(rifle, 0, 1.0), "too_many_pellets", "빈 보고")


func test_melee_validation() -> void:
	eq(CombatRules.check_melee(1, 1.0), "", "정상")
	eq(CombatRules.check_melee(3, 1.0), "", "세 명까지")
	eq(CombatRules.check_melee(4, 1.0), "too_many_targets", "대상이 너무 많음")
	eq(CombatRules.check_melee(0, 1.0), "too_many_targets", "빈 보고")
	eq(CombatRules.check_melee(1, 0.1), "too_fast", "너무 빠름")
	check(CombatRules.MELEE_DAMAGE * 2.0 >= 60.0, "돌진형은 두 번에 쓰러진다")


func test_grenade_damage_falls_off_to_zero() -> void:
	eq(CombatRules.grenade_damage(0.0), CombatRules.GRENADE_DAMAGE, "중심")
	eq(CombatRules.grenade_damage(CombatRules.GRENADE_RADIUS), 0.0, "가장자리")
	check(CombatRules.grenade_damage(2.5) > 0.0 and CombatRules.grenade_damage(2.5) < CombatRules.GRENADE_DAMAGE)


func test_loot_rolls_follow_probabilities() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var scrap := 0
	for i in 2000:
		scrap += int(CombatRules.roll_loot([["scrap", 1, 0.6], ["taint_crystal", 1, 0.0]], rng).get("scrap", 0))
	check(scrap > 1100 and scrap < 1300, "60%% 확률: 2000번 중 %d번" % scrap)
	eq(CombatRules.roll_loot([["energy_core", 1, 1.0]], rng), {"energy_core": 1}, "확정 전리품")


func test_enemy_data_is_valid() -> void:
	var db := ContentDB.load_from_dir("res://data")
	var defs := EnemyDef.load_all("res://data/enemies.json")
	eq(defs.size(), 6, "적 종류(골짜기 3 + 채석장 3)")
	for d in defs:
		check(d.hp > 0.0 and (d.speed > 0.0 or d.kind == &"turret") and d.attack_damage > 0.0, "%s 수치" % d.id)
		for row: Array in d.loot:
			check(db.items.has(StringName(str(row[0]))), "%s 전리품 '%s' 는 존재하는 아이템" % [d.id, row[0]])
