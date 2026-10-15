extends RefCounted
## Base class for SDK tests. Test methods are named `test_*` and may be coroutines.

const HttpResponse := preload("res://addons/gamebeast/internal/http_response.gd")
const Storage := preload("res://addons/gamebeast/internal/storage.gd")
const FakeTransport := preload("res://tests/fake_transport.gd")

var failures: PackedStringArray = PackedStringArray()
var tree: SceneTree
var _storage_dirs: Array = []


func assert_true(condition: bool, message: String = "expected true") -> void:
	if not condition:
		failures.append(message)


func assert_false(condition: bool, message: String = "expected false") -> void:
	assert_true(not condition, message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> void:
	if not _loose_equal(actual, expected):
		failures.append(
			"%s: expected %s, got %s" % [message, var_to_str(expected), var_to_str(actual)]
		)


## Equality where int and float compare by value, recursively (JSON makes every number a float).
static func _loose_equal(a: Variant, b: Variant) -> bool:
	if _is_number(a) and _is_number(b):
		return float(a) == float(b)
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in range(a.size()):
			if not _loose_equal(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _loose_equal(a[key], b[key]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func fresh_storage() -> Storage:
	var dir := "user://gamebeast_test/%d_%d" % [Time.get_ticks_usec(), randi()]
	_storage_dirs.append(dir)
	return Storage.new(dir)


func cleanup() -> void:
	for dir in _storage_dirs:
		_remove_dir(dir)
	_storage_dirs.clear()


## Let pending coroutines (fake responses resolved with call_deferred-free signals) run.
func settle() -> void:
	await tree.process_frame
	await tree.process_frame


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT


static func _remove_dir(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	DirAccess.remove_absolute(dir)
