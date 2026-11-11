extends SceneTree
## 헤드리스 테스트 실행기.
##   godot --headless -s tests/run_tests.gd
## tests/ 아래의 test_*.gd 를 모두 실행하고, 실패가 있으면 종료 코드 1.


func _initialize() -> void:
	var files: PackedStringArray = []
	_collect("res://tests", files)
	files.sort()
	var total := 0
	var failed := 0
	var checks := 0
	for path in files:
		var script: GDScript = load(path)
		if script == null:
			print("FAIL  %s (불러오기 실패)" % path)
			failed += 1
			continue
		for m: Dictionary in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			var t: TestCase = script.new()
			t.before_each()
			t.call(name)
			total += 1
			checks += t.checks
			if t.failures.is_empty():
				print("ok    %s :: %s" % [path.get_file(), name])
			else:
				failed += 1
				print("FAIL  %s :: %s" % [path.get_file(), name])
				for f in t.failures:
					print("        %s" % f)
	print("\n%d개 테스트, %d개 검사, %d개 실패" % [total, checks, failed])
	quit(1 if failed > 0 or total == 0 else 0)


func _collect(dir: String, out: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), out)
