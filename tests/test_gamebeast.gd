extends "res://tests/test_case.gd"
## End-to-end tests of the Gamebeast autoload with a fake transport.

const GamebeastScript := preload("res://addons/gamebeast/gamebeast.gd")
const ConfigTests := preload("res://tests/test_configs.gd")

var transport: FakeTransport
var sdk: Node


func before_each() -> void:
	transport = FakeTransport.new()
	transport.default_response = func(p):
		if p.url.contains("/configurations/evaluate"):
			return ConfigTests.config_response(
				"h-" + p.json["unit"]["distinctId"], {"Who": p.json["unit"]["distinctId"]}
			)
		return HttpResponse.of(200, "{}")
	sdk = GamebeastScript.new()
	tree.root.add_child(sdk)


func after_each() -> void:
	sdk.shutdown()
	sdk.queue_free()
	await settle()


func _setup(options: Variant) -> void:
	sdk._setup_internal(sdk._to_options(options), transport, fresh_storage())


func test_setup_from_dictionary() -> void:
	var initialized := [false]
	sdk.initialized.connect(func(): initialized[0] = true)
	_setup(
		{
			"api_key": "key",
			"environment": GamebeastOptions.EnvironmentMode.PRODUCTION,
			"configurations": ["Game"]
		}
	)
	assert_true(sdk.is_initialized(), "initialized")
	assert_true(initialized[0], "signal")
	assert_eq(sdk.get_environment(), "production", "environment")
	assert_true(sdk.get_session_id().begins_with("godot-"), "session id")
	await settle()
	assert_true(sdk.configs.is_ready(), "preloaded config ready")
	assert_eq(sdk.configs.get_value("Game.Who"), sdk.get_distinct_id(), "evaluated for this player")


func test_setup_requires_key_and_ignores_second_call() -> void:
	sdk.setup("")
	assert_false(sdk.is_initialized(), "empty key rejected")
	_setup("key-1")
	var first_session: String = sdk.get_session_id()
	_setup("key-2")
	assert_eq(sdk.get_session_id(), first_session, "second setup ignored")


func test_identify_and_reset() -> void:
	_setup({"api_key": "key", "configurations": ["Game"]})
	await settle()
	var anonymous: String = sdk.get_distinct_id()
	var changes: Array = []
	sdk.identity_changed.connect(func(id): changes.append(id))
	sdk.identify("player-9")
	await settle()
	assert_eq(sdk.get_distinct_id(), "player-9", "identified")
	assert_eq(sdk.configs.get_value("Game.Who"), "player-9", "configs re-evaluated")
	sdk.markers.send_marker("login")
	sdk.markers.flush()
	await settle()
	var marker: Dictionary = transport.requests_to("/sdk/v1/markers")[-1].json["markers"][0]
	assert_eq(marker["distinctId"], "player-9", "markers use new id")
	sdk.identify("player-9")
	sdk.reset_identity()
	await settle()
	assert_eq(sdk.get_distinct_id(), anonymous, "reset to anonymous id")
	assert_eq(changes, ["player-9", anonymous], "identity_changed emitted per change")


func test_shutdown_flushes_and_allows_setup_again() -> void:
	transport.manual = true
	_setup("key")
	sdk.markers.send_marker("quit")
	sdk.shutdown()
	assert_false(sdk.is_initialized(), "shut down")
	assert_eq(sdk.markers, null, "services gone")
	assert_eq(transport.waiting_count(), 1, "final flush sent")
	transport.resolve(HttpResponse.of(200, "{}"))
	await settle()
	transport.manual = false
	_setup("key")
	assert_true(sdk.is_initialized(), "setup again")


func test_session_rotates_after_background_timeout() -> void:
	_setup({"api_key": "key", "session_timeout_sec": 1800.0})
	var session: String = sdk.get_session_id()
	sdk._on_backgrounded()
	sdk._on_foregrounded()
	assert_eq(sdk.get_session_id(), session, "short background keeps session")
	sdk._on_backgrounded()
	sdk._backgrounded_at -= 2000.0
	sdk._on_foregrounded()
	assert_false(sdk.get_session_id() == session, "long background rotates session")
	sdk.markers.send_marker("e")
	sdk.markers.flush()
	await settle()
	var request = transport.requests_to("/sdk/v1/markers")[-1]
	assert_eq(request.headers["serverid"], sdk.get_session_id(), "serverid follows rotation")


func test_unknown_dictionary_options_are_ignored() -> void:
	_setup({"api_key": "key", "nope": 1})
	assert_true(sdk.is_initialized(), "still initializes")


func test_update_settings_changes_runtime_values() -> void:
	_setup("key")
	sdk.update_settings({"marker_batch_size": 2, "api_key": "other"})
	assert_eq(sdk._context.settings.marker_batch_size, 2, "batch size applied")
	assert_eq(sdk._context.options.api_key, "key", "setup-only setting refused")
	sdk.markers.send_marker("a")
	sdk.markers.send_marker("b")
	await settle()
	assert_eq(transport.requests_to("/sdk/v1/markers").size(), 1, "new batch size used")


func test_set_user_properties_re_evaluates() -> void:
	_setup({"api_key": "key", "configurations": ["Game"]})
	await settle()
	var before := transport.requests_to("/sdk/v2/configurations/evaluate").size()
	sdk.set_user_property("vip", true)
	await settle()
	var evaluations := transport.requests_to("/sdk/v2/configurations/evaluate")
	assert_eq(evaluations.size(), before + 1, "re-evaluated")
	assert_eq(evaluations[-1].json["context"]["properties"]["vip"], true, "property sent")
	sdk.set_user_property("vip", true)
	await settle()
	assert_eq(
		transport.requests_to("/sdk/v2/configurations/evaluate").size(), before + 1, "no-op skipped"
	)
