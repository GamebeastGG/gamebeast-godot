## The local player's distinct id: an explicit id (from options or identify()), or an anonymous
## dashed UUID generated once and persisted. OS.get_unique_id() is deliberately not used: it errors
## on Web and changes when the OS is reinstalled.

const Storage := preload("storage.gd")
const Uuid := preload("uuid.gd")

const FILE := "identity.json"

var anonymous_id: String
var explicit_id: String = ""

var distinct_id: String:
	get:
		return explicit_id if explicit_id != "" else anonymous_id


func _init(storage: Storage, initial_id: String = "") -> void:
	anonymous_id = _load_or_create_anonymous(storage)
	explicit_id = initial_id.strip_edges()


static func _load_or_create_anonymous(storage: Storage) -> String:
	var stored: Variant = storage.read_json(FILE)
	if stored is Dictionary and stored.get("anonymousId") is String and stored["anonymousId"] != "":
		return stored["anonymousId"]
	var id := Uuid.v4()
	storage.write_json(FILE, {"anonymousId": id})
	return id
