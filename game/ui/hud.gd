class_name Hud
extends Control
## 사격장 HUD: 조준선(탄퍼짐 반영), 적중 표시, 탄약, 통계, 도움말.

var player: PlayerController
var message: String = ""          ## 화면 위쪽 안내(도전 모드 등)

var _hit_time: float = 0.0
var _hit_color: Color = Color.WHITE
var _ammo: Label
var _stats: Label
var _help: Label
var _top: Label
var _paused: Label
var _version: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ammo = _label(Control.PRESET_BOTTOM_RIGHT, 34, HORIZONTAL_ALIGNMENT_RIGHT)
	_stats = _label(Control.PRESET_TOP_LEFT, 18, HORIZONTAL_ALIGNMENT_LEFT)
	_help = _label(Control.PRESET_BOTTOM_LEFT, 16, HORIZONTAL_ALIGNMENT_LEFT)
	_top = _label(Control.PRESET_CENTER_TOP, 26, HORIZONTAL_ALIGNMENT_CENTER)
	_paused = _label(Control.PRESET_CENTER, 28, HORIZONTAL_ALIGNMENT_CENTER)
	_version = _label(Control.PRESET_TOP_RIGHT, 14, HORIZONTAL_ALIGNMENT_RIGHT)
	_top.offset_top = 48.0
	_top.offset_bottom = 48.0
	_version.text = "Edenfall 사격 감각 테스트  v%s" % ProjectSettings.get_setting("application/config/version", "?")
	_version.modulate.a = 0.7
	_help.text = "\n".join([
		"WASD 이동 · Shift 달리기 · Space 점프 · Ctrl/C 앉기 (달리다 앉으면 슬라이딩)",
		"좌클릭 사격 · 우클릭 조준 · R 재장전 · 1/2/3 또는 휠 무기 교체",
		"[ ] 감도 · T 표적 도전 · F5 통계 초기화 · F1 수치 조정 · F11 전체 화면 · H 도움말 · Esc 일시정지",
	])
	_paused.text = "화면을 클릭하면 시작합니다"


func on_hit(_damage: float, head: bool, killed: bool) -> void:
	_hit_time = 0.22 if killed else 0.14
	_hit_color = Color(1.0, 0.25, 0.2) if killed else (Color(1.0, 0.85, 0.2) if head else Color.WHITE)


func toggle_help() -> void:
	_help.visible = not _help.visible


func _process(delta: float) -> void:
	if player == null:
		return
	_hit_time = maxf(_hit_time - delta, 0.0)
	var g := player.gun
	var ammo_text := "∞" if g.def.infinite_ammo else str(g.def.mag)
	_ammo.text = "%s\n%d / %s%s" % [g.def.display_name, g.mag, ammo_text, "  재장전…" if g.is_reloading() else ""]
	var acc := 100.0 * player.stat_hits / maxi(player.stat_shots, 1)
	var head_rate := 100.0 * player.stat_heads / maxi(player.stat_hits, 1)
	_stats.text = "FPS %d\n속도 %.1f m/s\n감도 ×%.2f\n\n발사 %d · 명중 %d (%.0f%%)\n머리 %.0f%% · 처치 %d\n누적 피해 %d" % [
		Engine.get_frames_per_second(), player.horizontal_speed(), player.sens_mult,
		player.stat_shots, player.stat_hits, acc, head_rate, player.stat_kills, roundi(player.stat_damage)]
	_top.text = message
	_paused.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and player.input_enabled
	queue_redraw()


func _draw() -> void:
	if player == null or player.camera == null:
		return
	var c := size * 0.5
	# 탄퍼짐 원뿔이 화면에서 차지하는 반지름(픽셀).
	var spread := deg_to_rad(player.current_spread())
	var gap := tan(spread) / tan(deg_to_rad(player.camera.fov * 0.5)) * size.y * 0.5
	gap = maxf(gap, 3.0)
	var fade := 1.0 - player.ads_amount * (0.0 if player.gun.def.pellets > 1 else 0.85)
	var col := Color(1, 1, 1, 0.9 * fade)
	var shadow := Color(0, 0, 0, 0.5 * fade)
	var length := 9.0
	for dir: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		draw_line(c + dir * gap, c + dir * (gap + length), shadow, 4.0)
		draw_line(c + dir * gap, c + dir * (gap + length), col, 2.0)
	draw_circle(c, 2.5, Color(0, 0, 0, 0.5))
	draw_circle(c, 1.5, Color(1, 1, 1, 0.95))
	if _hit_time > 0.0:
		var a := clampf(_hit_time / 0.14, 0.0, 1.0)
		var hc := Color(_hit_color, a)
		for d: Vector2 in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var n := d.normalized()
			draw_line(c + n * 8.0, c + n * 18.0, hc, 3.0)


func _label(preset: Control.LayoutPreset, font_size: int, align: HorizontalAlignment) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", font_size)
	l.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override(&"outline_size", 6)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	# 기준점(화면 비율 좌표)에 고정하고, 글자가 늘어나는 방향을 화면 안쪽으로 잡는다.
	var margin := 20.0
	var ax := 0.0 if align == HORIZONTAL_ALIGNMENT_LEFT else (1.0 if align == HORIZONTAL_ALIGNMENT_RIGHT else 0.5)
	var ay := 0.0
	if preset == Control.PRESET_BOTTOM_LEFT or preset == Control.PRESET_BOTTOM_RIGHT:
		ay = 1.0
	elif preset == Control.PRESET_CENTER:
		ay = 0.62
	l.anchor_left = ax
	l.anchor_right = ax
	l.anchor_top = ay
	l.anchor_bottom = ay
	var ox := margin if ax == 0.0 else (-margin if ax == 1.0 else 0.0)
	var oy := margin if ay == 0.0 else (-margin if ay == 1.0 else 0.0)
	l.offset_left = ox
	l.offset_right = ox
	l.offset_top = oy
	l.offset_bottom = oy
	l.grow_horizontal = Control.GROW_DIRECTION_END if ax == 0.0 else (Control.GROW_DIRECTION_BEGIN if ax == 1.0 else Control.GROW_DIRECTION_BOTH)
	l.grow_vertical = Control.GROW_DIRECTION_END if ay == 0.0 else (Control.GROW_DIRECTION_BEGIN if ay == 1.0 else Control.GROW_DIRECTION_BOTH)
	return l
