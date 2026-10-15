extends SceneTree
## Manual smoke test of the real HTTPRequest transport against a local server (not in CI).

const HttpTransport := preload("res://addons/gamebeast/internal/http_transport.gd")
const ApiClient := preload("res://addons/gamebeast/internal/api_client.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var host := Node.new()
	root.add_child(host)
	var api := ApiClient.new(HttpTransport.new(host), "key", "production", "http://127.0.0.1:8765")
	api.session_id = "godot-smoke"
	var first: Dictionary = await api.evaluate_configuration("Game", "", "p1", {"vip": true})
	print(
		"first: ",
		first["status"],
		" ",
		first["response"]["configuration"] if first["response"] else null
	)
	var second: Dictionary = await api.evaluate_configuration("Game", "h1", "p1", {})
	print("second (expect NOT_MODIFIED=1): ", second["status"])
	var markers = await api.post_markers([{"eventName": "x"}])
	print("markers: ", markers.status, " retry-after=", markers.retry_after_sec())
	var missing: Dictionary = await api.get_active_experiments("")
	print("experiments 404: ", missing["status"], " ", missing["error"])
	var offline := ApiClient.new(HttpTransport.new(host), "k", "production", "http://127.0.0.1:1")
	var down = await offline.post_markers([])
	print("offline: ", down.describe())
	quit()
