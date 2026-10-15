extends SceneTree
## Headless test runner: godot --headless --path . -s tests/run_tests.gd
## Runs every `test_*` method of every res://tests/test_*.gd file and exits non-zero on failure.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	preload("res://addons/gamebeast/internal/log.gd").silenced = (
		OS.get_environment("GB_TEST_LOGS") == ""
	)
	var files := Array(DirAccess.get_files_at("res://tests")).filter(
		func(f: String):
			return f.begins_with("test_") and f.ends_with(".gd") and f != "test_case.gd"
	)
	files.sort()
	var only := OS.get_environment("GB_TEST_FILTER")
	var passed := 0
	var failed := 0
	for file in files:
		var script: GDScript = load("res://tests/" + file)
		for method in script.get_script_method_list():
			var name: String = method["name"]
			if not name.begins_with("test_") or (only != "" and not name.contains(only)):
				continue
			var test: RefCounted = script.new()
			test.tree = self
			if test.has_method("before_each"):
				await test.before_each()
			await test.call(name)
			if test.has_method("after_each"):
				await test.after_each()
			test.cleanup()
			if test.failures.is_empty():
				passed += 1
				print("  ok   %s::%s" % [file, name])
			else:
				failed += 1
				print("  FAIL %s::%s" % [file, name])
				for failure in test.failures:
					print("         " + failure)
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
