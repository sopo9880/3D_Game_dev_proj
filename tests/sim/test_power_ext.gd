extends TestCase

var db: ContentDB
var w: SimWorld


func before_each() -> void:
	db = ContentDB.load_from_dir("res://data")
	w = SimWorld.new(db)
	w.ensure_player("ann")


func _run(ticks: int) -> void:
	for i in ticks:
		w.tick()


## 제련기 한 대(수요 15)에 광석을 계속 넣어 주는 준비.
func _smelter(cell: Vector3i) -> SimStructure:
	var s := w.place(&"smelter", cell)
	w.insert(s.id, &"iron_ore", 4)
	return s


func test_solar_runs_without_fuel() -> void:
	var panel_a := w.place(&"solar_panel", Vector3i(0, 0, 0))
	var panel_b := w.place(&"solar_panel", Vector3i(3, 0, 0))
	var s := _smelter(Vector3i(0, 0, 4))
	check(panel_a != null and panel_b != null, "태양광 설치")
	_run(5)
	eq(s.grid.supply, 16, "태양광 2대 = 16")
	eq(s.state, SimStructure.State.RUNNING, "연료 없이 가동")
	eq(panel_a.fuel_count, 0, "연료를 쓰지 않는다")


func test_one_solar_is_not_enough_and_slows_proportionally() -> void:
	w.place(&"solar_panel", Vector3i(0, 0, 0))
	var s := _smelter(Vector3i(0, 0, 4))
	_run(5)
	eq(s.grid.ratio, 533, "8 / 15")
	eq(s.state, SimStructure.State.RUNNING, "느리게라도 돈다")


func test_wind_turbine_output() -> void:
	w.place(&"wind_turbine", Vector3i(0, 0, 0))
	var s := _smelter(Vector3i(0, 0, 4))
	_run(5)
	eq(s.grid.supply, 15, "풍력 15")
	eq(s.grid.ratio, 1000, "제련기 한 대를 온전히 돌린다")


func test_battery_stores_surplus_and_covers_shortage() -> void:
	# 풍력 2대(30) + 제련기 1대(15): 남는 15가 축전지에 쌓인다.
	var t1 := w.place(&"wind_turbine", Vector3i(0, 0, 0))
	var t2 := w.place(&"wind_turbine", Vector3i(3, 0, 0))
	var bat := w.place(&"battery", Vector3i(6, 0, 0))
	var s := _smelter(Vector3i(0, 0, 4))
	check(bat != null, "축전지 설치")
	_run(10)
	check(bat.grid != null, "축전지가 전력망에 붙는다")
	check(bat.charge >= 100 and bat.charge <= 150, "10틱 동안 남는 전력 15씩 충전: %d" % bat.charge)
	# 발전기를 철거하면 축전지가 대신 공급한다.
	var stored := bat.charge
	w.remove(t1.id)
	w.remove(t2.id)
	w.insert(s.id, &"iron_ore", 4)
	_run(3)
	check(bat.grid == null, "공급원이 없으면 전력망도 없다")
	eq(bat.charge, stored, "전력망이 없으면 방전하지 않는다")
	# 중계 기둥으로 망을 다시 만들면 축전지가 제련기를 돌린다.
	w.place(&"power_pole", Vector3i(3, 0, 3))
	_run(4)
	check(bat.charge < stored, "모자란 만큼 방전: %d → %d" % [stored, bat.charge])
	eq(s.grid.ratio, 1000, "축전지 덕분에 충족률 100%")
	eq(s.state, SimStructure.State.RUNNING, "제련기 가동")


func test_battery_respects_capacity_and_rate() -> void:
	for i in 4:
		w.place(&"wind_turbine", Vector3i(i * 3, 0, 0))   # 공급 60, 수요 0
	var bat := w.place(&"battery", Vector3i(0, 0, 4))
	_run(1)
	eq(bat.charge, 30, "틱당 충전 한도 30")
	_run(400)
	eq(bat.charge, 6000, "용량 6000에서 멈춘다")


func test_two_batteries_do_not_double_count_surplus() -> void:
	w.place(&"wind_turbine", Vector3i(0, 0, 0))    # 공급 15, 수요 0
	var a := w.place(&"battery", Vector3i(3, 0, 0))
	var b := w.place(&"battery", Vector3i(6, 0, 0))
	_run(1)
	eq(a.charge + b.charge, 15, "남는 15를 둘이 나눠 갖는다(각자 15씩이 아니다)")


func test_eco_bonus_in_restored_zone() -> void:
	var zone := db.zones[0]
	var inside := Vector3i(zone.unlock_zone[0] + 10, 0, zone.unlock_zone[1] + 10)
	w.add_build_zone(zone.unlock_zone[0], zone.unlock_zone[1], zone.unlock_zone[2], zone.unlock_zone[3], 0)
	var panel := w.place(&"solar_panel", inside)
	_run(2)
	eq(panel.grid.supply, 8, "복원 전에는 기본 출력")
	w.restore[zone.index] = 100
	w._dirty = true
	_run(2)
	eq(panel.grid.supply, 12, "복원된 구역 안에서는 1.5배")


func test_battery_charge_survives_save() -> void:
	w.place(&"wind_turbine", Vector3i(0, 0, 0))
	var bat := w.place(&"battery", Vector3i(3, 0, 0))
	_run(20)
	var loaded := SimWorld.from_dict(db, bytes_to_var(var_to_bytes(w.to_dict())))
	eq(loaded.to_dict(), w.to_dict(), "저장 왕복")
	eq(loaded.batteries[0].charge, bat.charge, "충전량")
	for i in 50:
		w.tick()
		loaded.tick()
	eq(loaded.state_hash(), w.state_hash(), "이후에도 같은 상태")
