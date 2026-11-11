class_name TestCase
extends RefCounted
## 최소 테스트 기반 클래스. test_ 로 시작하는 메서드가 테스트다.

var failures: PackedStringArray = []
var checks: int = 0


func check(cond: bool, msg: String = "") -> void:
	checks += 1
	if not cond:
		failures.append(msg if msg != "" else "조건이 거짓")


func eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: 기대 %s, 실제 %s" % [msg, str(expected), str(actual)])


func before_each() -> void:
	pass
