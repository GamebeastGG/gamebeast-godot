## Small JSON file store under user://gamebeast/. On Web exports user:// is backed by IndexedDB
## and synced asynchronously, so writes made while the page is closing are best-effort.

const Constants := preload("constants.gd")
const JsonCodec := preload("json_codec.gd")
const Log := preload("log.gd")

var _dir: String


func _init(dir: String = Constants.STORAGE_DIR) -> void:
	_dir = dir


func path_for(file_name: String) -> String:
	return _dir.path_join(file_name)


func read_json(file_name: String) -> Variant:
	var path := path_for(file_name)
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		Log.warn("Could not read %s (error %d)." % [path, FileAccess.get_open_error()])
		return null
	var text := file.get_as_text()
	file.close()
	return JsonCodec.parse(text)


func write_json(file_name: String, value: Variant) -> bool:
	if (
		DirAccess.make_dir_recursive_absolute(_dir) != OK
		and not DirAccess.dir_exists_absolute(_dir)
	):
		Log.warn("Could not create %s." % _dir)
		return false
	var path := path_for(file_name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Log.warn("Could not write %s (error %d)." % [path, FileAccess.get_open_error()])
		return false
	file.store_string(JsonCodec.stringify(value))
	file.close()
	return true


func delete(file_name: String) -> void:
	var path := path_for(file_name)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Lowercase, filename-safe version of an alias.
static func safe_name(value: String) -> String:
	var out := ""
	for c in value.to_lower():
		out += (
			c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") or c == "-" or c == "_" else "_"
		)
	return out if out != "" else "_"
