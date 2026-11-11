class_name Sfx
extends Node
## 임시 효과음. 실제 사운드 에셋이 들어오기 전까지 코드로 합성해 쓴다.

const RATE := 44100

var _players: Dictionary[StringName, AudioStreamPlayer] = {}


func _ready() -> void:
	_add(&"shot_pistol", _gunshot(0.16, 190.0, 0.55, 0.9, 11), -4.0)
	_add(&"shot_rifle", _gunshot(0.14, 150.0, 0.7, 1.0, 12), -5.0)
	_add(&"shot_shotgun", _gunshot(0.34, 85.0, 1.0, 0.55, 13), -1.0)
	_add(&"hit", _blip(0.045, 1250.0, 900.0), -9.0)
	_add(&"head", _blip(0.12, 2300.0, 2300.0), -6.0)
	_add(&"kill", _blip(0.16, 700.0, 1500.0), -5.0)
	_add(&"empty", _click(0.03, 21), -10.0)
	_add(&"reload", _click(0.07, 22), -8.0)
	_add(&"shell", _click(0.04, 23), -9.0)
	_add(&"jump", _thump(0.06, 180.0), -14.0)
	_add(&"land", _thump(0.1, 90.0), -9.0)
	_add(&"slide", _noise_swish(0.45), -12.0)


func play(id: StringName, pitch_jitter: float = 0.0) -> void:
	var p: AudioStreamPlayer = _players.get(id)
	if p == null:
		return
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


func _add(id: StringName, stream: AudioStreamWAV, volume_db: float) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	p.max_polyphony = 8
	add_child(p)
	_players[id] = p


func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	return wav


## 총소리: 짧은 잡음 폭발 + 아래로 떨어지는 저음.
func _gunshot(length: float, thump_hz: float, body: float, brightness: float, seed_value: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var noise := rng.randf_range(-1.0, 1.0)
		lp = lerpf(lp, noise, brightness)
		var crack := lp * exp(-t * 38.0 / maxf(length * 6.0, 0.6))
		var hz := thump_hz * (0.35 + 0.65 * exp(-t * 22.0))
		phase += TAU * hz / RATE
		var thump := sin(phase) * exp(-t * 16.0) * body
		var attack := minf(t * 2500.0, 1.0)
		out[i] = (crack * 0.8 + thump * 0.75) * attack
	return _wav(out)


func _blip(length: float, hz_from: float, hz_to: float) -> AudioStreamWAV:
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		phase += TAU * lerpf(hz_from, hz_to, t) / RATE
		out[i] = sin(phase) * (1.0 - t) * (1.0 - t) * 0.8
	return _wav(out)


func _click(length: float, seed_value: int) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / n
		out[i] = (rng.randf_range(-1.0, 1.0) * 0.5 + sin(float(i) * 0.5) * 0.5) * exp(-t * 9.0)
	return _wav(out)


func _thump(length: float, hz: float) -> AudioStreamWAV:
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		phase += TAU * hz * (1.0 - t * 0.5) / RATE
		out[i] = sin(phase) * (1.0 - t)
	return _wav(out)


func _noise_swish(length: float) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var n := int(length * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var lp := 0.0
	for i in n:
		var t := float(i) / n
		lp = lerpf(lp, rng.randf_range(-1.0, 1.0), 0.12)
		out[i] = lp * sin(t * PI) * 1.6
	return _wav(out)
