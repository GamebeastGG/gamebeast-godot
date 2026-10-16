extends "res://tests/test_case.gd"

const Context := preload("res://addons/gamebeast/internal/context.gd")

var transport: FakeTransport
var storage: Storage


func before_each() -> void:
	transport = FakeTransport.new()
	storage = fresh_storage()


func _context(configurations: Array = [], user_properties: Dictionary = {}) -> Context:
	var options := GamebeastOptions.with_api_key("key")
	options.configurations = PackedStringArray(configurations)
	options.user_properties = user_properties
	return Context.new(options, "development", transport, storage)


static func config_response(
	hash: String, values: Dictionary, experiments: Array = []
) -> HttpResponse:
	return (
		FakeTransport
		. json(
			200,
			{
				"hash": hash,
				"configurationId": 1,
				"name": "Game Settings",
				"configuration": values,
				"privacy": [],
				"updatedAt": "2026-10-01T00:00:00.000Z",
				"experiments": experiments,
				"requiredProperties": [],
			}
		)
	)


func _evaluate_requests() -> Array:
	return transport.requests_to("/sdk/v2/configurations/evaluate")


func test_evaluate_request_shape() -> void:
	transport.queued = [config_response("h1", {"Speed": 16})]
	var context := _context(["GameSettings"], {"vip": true, "tier": &"gold", "bad": Node})
	var configs := GamebeastConfigs.new(context)
	configs._start()
	await settle()
	var request = _evaluate_requests()[0]
	assert_eq(request.json["configuration"], "GameSettings", "alias")
	assert_eq(request.json["unit"], {"type": "user", "distinctId": context.distinct_id()}, "unit")
	assert_eq(request.json["context"]["schemaVersion"], 1, "schema version")
	var properties: Dictionary = request.json["context"]["properties"]
	assert_eq(properties["vip"], true, "custom property")
	assert_eq(properties["tier"], "gold", "StringName coerced")
	assert_false(properties.has("bad"), "objects skipped")
	assert_true(properties.has("platform") and properties.has("appVersion"), "device properties")
	assert_false(request.json.has("knownHash"), "no hash on first fetch")
	assert_eq(request.headers["environment"], "development", "environment header")
	assert_false(request.headers.has("isstudio"), "no isstudio on v2")


func test_reads_and_typed_getters() -> void:
	transport.queued = [
		config_response(
			"h1",
			{
				"Speed": 16,
				"Ratio": 0.5,
				"Name": "hero",
				"On": true,
				"UI": {"Color": "red"},
				"Levels": [{"Boss": "Spider"}],
				"Count": "7",
			}
		)
	]
	var configs := GamebeastConfigs.new(_context(["GameSettings"]))
	configs._start()
	await settle()
	assert_true(configs.is_ready(), "ready")
	assert_eq(configs.get_int("GameSettings.Speed"), 16, "int from JSON float")
	assert_eq(typeof(configs.get_int("GameSettings.Speed")), TYPE_INT, "int type")
	assert_eq(configs.get_float("GameSettings.Ratio"), 0.5, "float")
	assert_eq(configs.get_string("GameSettings.Name"), "hero", "string")
	assert_eq(configs.get_string("GameSettings.Speed"), "16", "whole float as string")
	assert_eq(configs.get_bool("GameSettings.On"), true, "bool")
	assert_eq(configs.get_value("GameSettings.UI.Color"), "red", "nested")
	assert_eq(configs.get_value("GameSettings.Levels.0.Boss"), "Spider", "array index")
	assert_eq(configs.get_int("GameSettings.Count"), 7, "numeric string")
	assert_eq(configs.get_int("GameSettings.Missing", 42), 42, "default when missing")
	assert_eq(configs.get_int("GameSettings.Name", -1), -1, "default on type mismatch")
	assert_eq(configs.get_value("gamesettings.Speed"), 16, "alias is case-insensitive")
	assert_eq(
		configs.try_get("GameSettings.Missing"), {"found": false, "value": null}, "try_get miss"
	)
	assert_eq(configs.try_get("GameSettings.Speed")["found"], true, "try_get hit")
	assert_eq(configs.get_dict("GameSettings").size(), 7, "bare alias returns document")
	var copy: Dictionary = configs.get_dict("GameSettings.UI")
	copy["Color"] = "blue"
	assert_eq(configs.get_value("GameSettings.UI.Color"), "red", "returned dicts are copies")


func test_lazy_load_on_first_read() -> void:
	transport.manual = true
	var configs := GamebeastConfigs.new(_context())
	assert_true(configs.is_ready(), "ready with nothing preloaded")
	assert_eq(configs.get_value("Other.A", "pending"), "pending", "default before load")
	await settle()
	assert_eq(_evaluate_requests().size(), 1, "read triggered a fetch")
	transport.resolve(config_response("h1", {"A": 1}))
	await settle()
	assert_eq(configs.get_value("Other.A"), 1, "value after load")


func test_ready_signal_and_callback() -> void:
	transport.manual = true
	var configs := GamebeastConfigs.new(_context(["A", "B"]))
	var fired := [0, 0]
	configs.configs_ready.connect(func(): fired[0] += 1)
	configs.on_ready(func(): fired[1] += 1)
	configs._start()
	await settle()
	assert_eq(transport.waiting_count(), 2, "both preloads in flight")
	transport.resolve(config_response("ha", {}))
	await settle()
	assert_false(configs.is_ready(), "not ready with one of two")
	transport.resolve(config_response("hb", {}))
	await settle()
	assert_true(configs.is_ready(), "ready")
	assert_eq(fired, [1, 1], "signal and callback fired once")
	var late := [false]
	configs.on_ready(func(): late[0] = true)
	assert_true(late[0], "on_ready after ready fires immediately")


func test_observe_and_on_changed() -> void:
	transport.manual = true
	var configs := GamebeastConfigs.new(_context(["Game"]))
	var observed: Array = []
	var changed: Array = []
	configs.observe("Game.Speed", func(v): observed.append(v))
	configs.on_changed("Game.Speed", func(v): changed.append(v))
	configs._start()
	await settle()
	transport.resolve(config_response("h1", {"Speed": 1, "Other": 1}))
	await settle()
	assert_eq(observed, [1], "observe fires on initial load")
	assert_eq(changed, [], "on_changed skips initial load")
	configs.refresh()
	await settle()
	transport.resolve(config_response("h2", {"Speed": 1, "Other": 2}))
	await settle()
	assert_eq(changed, [], "unrelated change doesn't fire")
	configs.refresh()
	await settle()
	assert_eq(_evaluate_requests()[-1].json["knownHash"], "h2", "known hash sent")
	transport.resolve(config_response("h3", {"Speed": 5, "Other": 2}))
	await settle()
	assert_eq(observed, [1, 5], "observe fires on change")
	assert_eq(changed, [5], "on_changed fires on change")
	var late: Array = []
	configs.observe("Game.Speed", func(v): late.append(v))
	assert_eq(late, [5], "observe after load fires immediately")


func test_cancelled_and_freed_subscribers_stop() -> void:
	transport.manual = true
	var configs := GamebeastConfigs.new(_context(["Game"]))
	var calls: Array = []
	var subscription := configs.on_changed("Game.X", func(v): calls.append(v))
	var node := Node.new()
	# A method callable on a node: once the node is freed, the subscription drops itself.
	var freed_subscription := configs.on_changed("Game.X", Callable(node, "set_name"))
	configs._start()
	await settle()
	transport.resolve(config_response("h1", {"X": 1}))
	await settle()
	subscription.cancel()
	node.free()
	assert_false(freed_subscription.is_active(), "freed target deactivates subscription")
	configs.refresh()
	await settle()
	transport.resolve(config_response("h2", {"X": 2}))
	await settle()
	assert_eq(calls, [], "cancelled subscriber not called")


func test_not_modified_keeps_values() -> void:
	transport.queued = [config_response("h1", {"A": 1}), HttpResponse.of(304)]
	var configs := GamebeastConfigs.new(_context(["Game"]))
	await configs.refresh()
	await configs.refresh()
	assert_eq(_evaluate_requests().size(), 2, "two requests")
	assert_eq(configs.get_value("Game.A"), 1, "values kept on 304")


func test_disk_cache_serves_next_launch() -> void:
	transport.queued = [config_response("h1", {"A": 1})]
	var context := _context(["Game"])
	var configs := GamebeastConfigs.new(context)
	await configs.refresh()

	transport.manual = true
	var next_context := Context.new(context.options, "development", transport, storage)
	var next := GamebeastConfigs.new(next_context)
	assert_true(next.is_ready(), "ready from cache before the network")
	assert_eq(next.get_value("Game.A"), 1, "cached value")
	next._start()
	await settle()
	assert_eq(_evaluate_requests()[-1].json["knownHash"], "h1", "revalidates with cached hash")


func test_cache_ignored_for_other_player() -> void:
	transport.queued = [config_response("h1", {"A": 1})]
	var context := _context(["Game"])
	await GamebeastConfigs.new(context).refresh()
	var options := context.options.duplicate_options()
	options.distinct_id = "someone-else"
	transport.manual = true
	var other := GamebeastConfigs.new(Context.new(options, "development", transport, storage))
	assert_false(other.is_ready(), "cache keyed by distinct id")


func test_identity_change_discards_in_flight() -> void:
	transport.manual = true
	var context := _context(["Game"])
	var configs := GamebeastConfigs.new(context)
	configs._start()
	await settle()
	context.identity.explicit_id = "player-2"
	configs._on_identity_changed()
	transport.resolve(config_response("old", {"Who": "old"}))
	await settle()
	assert_eq(configs.get_value("Game.Who"), null, "stale response discarded")
	assert_eq(transport.waiting_count(), 1, "refetch for new player")
	var refetch = transport.requests[-1]
	assert_eq(refetch.json["unit"]["distinctId"], "player-2", "new distinct id")
	assert_false(refetch.json.has("knownHash"), "hash dropped")
	transport.resolve(config_response("new", {"Who": "new"}))
	await settle()
	assert_eq(configs.get_value("Game.Who"), "new", "new player's values")


func test_failed_preload_retries_sooner() -> void:
	transport.queued = [HttpResponse.failed("offline"), config_response("h1", {"A": 1})]
	var context := _context(["Game"])
	context.options.config_refresh_interval_sec = 0.0
	var configs := GamebeastConfigs.new(context)
	await configs.refresh()
	assert_false(configs.is_ready(), "not ready after failure")
	configs._tick(10.0)
	await settle()
	assert_true(configs.is_ready(), "retried with refresh disabled")


func test_interval_refresh() -> void:
	transport.default_response = func(_p): return config_response("h", {})
	var context := _context(["Game"])
	context.options.config_refresh_interval_sec = 60.0
	context.resolve_settings()
	var configs := GamebeastConfigs.new(context)
	await configs.refresh()
	configs._tick(59.0)
	await settle()
	assert_eq(_evaluate_requests().size(), 1, "not yet")
	configs._tick(1.5)
	await settle()
	assert_eq(_evaluate_requests().size(), 2, "refreshed after 60s")


func test_concurrent_refreshes_share_request() -> void:
	transport.manual = true
	var configs := GamebeastConfigs.new(_context(["Game"]))
	configs.refresh()
	configs.refresh()
	await settle()
	assert_eq(transport.waiting_count(), 1, "deduplicated")
	transport.resolve(config_response("h", {}))
	await settle()


func test_not_found_is_reported() -> void:
	transport.queued = [
		FakeTransport.json(404, {"errorCode": "CONFIGURATION_NOT_FOUND", "message": "x"})
	]
	var configs := GamebeastConfigs.new(_context(["Missing"]))
	await configs.refresh()
	assert_false(configs.is_ready(), "missing config never ready")


static func status_response(
	hash: String, config_hashes: Dictionary, experiments: Array = [], polling: Variant = null
) -> HttpResponse:
	var configurations: Array = []
	var id := 1
	for alias in config_hashes:
		configurations.append(
			{"id": id, "name": alias, "alias": alias, "hash": config_hashes[alias]}
		)
		id += 1
	var body := {
		"hash": hash,
		"configurations": configurations,
		"primaryConfigurationId": 1,
		"experiments": {"user": experiments, "server": []},
		"requiredProperties": [],
	}
	if polling != null:
		body["polling"] = polling
	return FakeTransport.json(200, body, {"etag": '"%s"' % hash})


func _status_requests() -> Array:
	return transport.requests_to("/sdk/v2/status")


func _status_context() -> Context:
	transport.default_response = func(_p): return config_response("h", {})
	var context := _context(["Game", "Other"])
	context.options.status_poll_interval_sec = 30.0
	context.options.config_refresh_interval_sec = 0.0
	context.resolve_settings()
	return context


func test_status_poll_headers_and_304_skips_evaluate() -> void:
	var snapshots := [
		status_response("s1", {"Game": "g1", "Other": "o1"}), HttpResponse.of(304, "")
	]
	transport.routes["/sdk/v2/status"] = func(_p): return snapshots.pop_front()
	var configs := GamebeastConfigs.new(_status_context())
	configs._start()
	await settle()
	assert_eq(_evaluate_requests().size(), 2, "startup evaluates both")
	var first = _status_requests()[0]
	assert_eq(first.headers["environment"], "development", "environment header")
	assert_true(first.headers.has("server-id"), "server-id for a per-player rate-limit bucket")
	assert_false(first.headers.has("if-none-match"), "no etag on first poll")
	configs._tick(30.5)
	await settle()
	assert_eq(_status_requests().size(), 2, "polled again after the interval")
	assert_eq(_status_requests()[1].headers["if-none-match"], '"s1"', "sends last hash")
	assert_eq(_evaluate_requests().size(), 2, "unchanged snapshot: no re-evaluation")


func test_status_change_re_evaluates_only_changed_config() -> void:
	var snapshots := [
		status_response("s1", {"Game": "g1", "Other": "o1"}),
		status_response("s2", {"Game": "g2", "Other": "o1"}),
	]
	transport.routes["/sdk/v2/status"] = func(_p): return snapshots.pop_front()
	var configs := GamebeastConfigs.new(_status_context())
	configs._start()
	await settle()
	configs._tick(30.5)
	await settle()
	var evaluated: Array = _evaluate_requests().map(func(r): return r.json["configuration"])
	assert_eq(evaluated.size(), 3, "one re-evaluation")
	assert_eq(evaluated[2], "Game", "the changed configuration")


func test_experiment_change_re_evaluates_all_and_reports_catalog() -> void:
	var experiment := {"id": 7, "name": "Speed", "groups": [{"id": 20, "label": "A"}]}
	var snapshots := [
		status_response("s1", {"Game": "g1", "Other": "o1"}),
		status_response("s2", {"Game": "g1", "Other": "o1"}, [experiment]),
	]
	transport.routes["/sdk/v2/status"] = func(_p): return snapshots.pop_front()
	var configs := GamebeastConfigs.new(_status_context())
	var catalogs: Array = []
	configs.catalog_reporter = func(list): catalogs.append(list)
	configs._start()
	await settle()
	configs._tick(30.5)
	await settle()
	assert_eq(_evaluate_requests().size(), 4, "new experiment: every configuration re-evaluated")
	assert_eq(catalogs[-1][0]["name"], "Speed", "descriptors reported for names")


func test_status_polling_floor_and_retry_after() -> void:
	var snapshots := [
		status_response("s1", {"Game": "g1"}, [], {"intervalSeconds": 300, "jitterRatio": 0.0}),
		FakeTransport.json(429, {}, {"retry-after": "900"}),
	]
	transport.routes["/sdk/v2/status"] = func(_p): return snapshots.pop_front()
	var configs := GamebeastConfigs.new(_status_context())
	configs._start()
	await settle()
	configs._tick(299.0)
	await settle()
	assert_eq(_status_requests().size(), 1, "backend floor of 300s beats the 30s setting")
	configs._tick(2.0)
	await settle()
	assert_eq(_status_requests().size(), 2, "polled at the floor")
	configs._tick(899.0)
	await settle()
	assert_eq(_status_requests().size(), 2, "retry-after honoured")


func test_status_disabled_makes_no_requests() -> void:
	var context := _context(["Game"])
	context.options.status_poll_interval_sec = 0.0
	context.resolve_settings()
	var configs := GamebeastConfigs.new(context)
	configs._start()
	configs._tick(1000.0)
	await settle()
	assert_eq(_status_requests().size(), 0, "no status polling")
