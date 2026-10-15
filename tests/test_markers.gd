extends "res://tests/test_case.gd"

const Context := preload("res://addons/gamebeast/internal/context.gd")
const Uuid := preload("res://addons/gamebeast/internal/uuid.gd")

var transport: FakeTransport
var storage: Storage


func before_each() -> void:
	transport = FakeTransport.new()
	storage = fresh_storage()


func _context(alias: String = "development") -> Context:
	var options := GamebeastOptions.with_api_key("key")
	return Context.new(options, alias, transport, storage)


func _marker_requests() -> Array:
	return transport.requests_to("/sdk/v1/markers")


func test_marker_shape_and_headers() -> void:
	var context := _context()
	var markers := GamebeastMarkers.new(context)
	markers.send_marker("level_completed", {"level": 3, "pos": Vector3(1, 2, 3)})
	markers.flush()
	await settle()
	var sent := _marker_requests()
	assert_eq(sent.size(), 1, "one request")
	var marker: Dictionary = sent[0].json["markers"][0]
	assert_eq(marker["eventName"], "level_completed", "eventName")
	assert_true(Uuid.is_uuid(marker["markerId"]), "dashed uuid markerId")
	assert_eq(marker["distinctId"], context.distinct_id(), "distinctId")
	assert_eq(marker["sessionId"], context.session_id, "sessionId")
	assert_true(str(marker["sessionId"]).begins_with("godot-"), "session prefix")
	assert_eq(marker["properties"]["pos"], [1, 2, 3], "vector payload")
	assert_true(marker["timestamp"] > 1_700_000_000_000, "epoch ms timestamp")
	assert_eq(sent[0].headers["isstudio"], "true", "development isstudio")
	assert_eq(sent[0].headers["serverid"], context.session_id, "serverid")


func test_batches_of_ten_flush_immediately() -> void:
	var markers := GamebeastMarkers.new(_context())
	for i in range(25):
		markers.send_marker("e", {"i": i})
	await settle()
	assert_eq(_marker_requests().size(), 2, "two full batches sent")
	assert_eq(markers.buffered_count(), 5, "five waiting")
	markers._tick(10.0)
	await settle()
	assert_eq(_marker_requests().size(), 3, "interval flush")
	assert_eq(_marker_requests()[2].json["markers"].size(), 5, "remainder batch")


func test_send_position_maps_2d_to_xz() -> void:
	var markers := GamebeastMarkers.new(_context())
	markers.send_position("death", Vector2(10, 20), {"cause": "lava"})
	markers.send_position("death3d", Vector3(1, 2, 3))
	markers.flush()
	await settle()
	var sent: Array = _marker_requests()[0].json["markers"]
	assert_eq(sent[0]["properties"]["position"], [10, 0, 20], "2D -> [x, 0, y]")
	assert_eq(sent[0]["properties"]["cause"], "lava", "extra props kept")
	assert_eq(sent[1]["properties"]["position"], [1, 2, 3], "3D as-is")


func test_retry_backoff_honours_retry_after() -> void:
	transport.queued = [
		FakeTransport.json(503, {}),
		FakeTransport.json(429, {}, {"retry-after": "30"}),
		FakeTransport.json(200, {}),
	]
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("e")
	markers.flush()
	await settle()
	assert_eq(_marker_requests().size(), 1, "first attempt")
	markers._tick(1.9)
	await settle()
	assert_eq(_marker_requests().size(), 1, "waits 2s")
	markers._tick(0.2)
	await settle()
	assert_eq(_marker_requests().size(), 2, "second attempt after 2s")
	markers._tick(4.5)
	await settle()
	assert_eq(_marker_requests().size(), 2, "retry-after 30s beats 4s backoff")
	markers._tick(26.0)
	await settle()
	assert_eq(_marker_requests().size(), 3, "third attempt")
	assert_eq(markers.buffered_count(), 0, "delivered")
	var ids: Array = _marker_requests().map(func(r): return r.json["markers"][0]["markerId"])
	assert_eq(ids[0], ids[2], "retries resend the same marker id")


func test_permanent_rejection_drops_batch() -> void:
	transport.queued = [FakeTransport.json(400, {"errorCode": "INVALID"})]
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("e")
	markers.flush()
	await settle()
	markers._tick(100.0)
	await settle()
	assert_eq(_marker_requests().size(), 1, "no retry on 400")
	assert_eq(markers.buffered_count(), 0, "dropped")


func test_gives_up_after_five_attempts() -> void:
	transport.default_response = func(_p): return HttpResponse.failed("offline")
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("e")
	markers.flush()
	for i in range(10):
		await settle()
		markers._tick(20.0)
	await settle()
	assert_eq(_marker_requests().size(), 5, "five attempts total")
	assert_eq(markers.buffered_count(), 0, "dropped after max attempts")


func test_persist_and_replay_next_launch() -> void:
	transport.manual = true
	var context := _context()
	var markers := GamebeastMarkers.new(context)
	markers.send_marker("a")
	markers.send_marker("b")
	markers.flush()  # in flight, never answered (the game is killed)
	markers.send_marker("c")
	markers._persist()
	var ids := [
		transport.requests[0].json["markers"][0]["markerId"],
		transport.requests[0].json["markers"][1]["markerId"],
	]

	var next_transport := FakeTransport.new()
	var next_context := Context.new(
		GamebeastOptions.with_api_key("key"), "development", next_transport, storage
	)
	var restored := GamebeastMarkers.new(next_context)
	assert_eq(restored.buffered_count(), 3, "restored in-flight and pending markers")
	restored._tick(0.1)
	await settle()
	var sent: Array = next_transport.requests_to("/sdk/v1/markers")[0].json["markers"]
	assert_eq(sent.map(func(m): return m["eventName"]), ["a", "b", "c"], "replayed in order")
	assert_eq(sent[0]["markerId"], ids[0], "original marker id kept")
	assert_eq(sent[0]["sessionId"], context.session_id, "original session kept")
	assert_eq(storage.read_json("markers_development.json"), null, "disk copy cleared after send")


func test_persist_files_are_per_environment() -> void:
	transport.manual = true
	var markers := GamebeastMarkers.new(_context("production"))
	markers.send_marker("x")
	markers._persist()
	assert_true(storage.read_json("markers_production.json") is Array, "production file")
	assert_eq(storage.read_json("markers_development.json"), null, "no development file")


func test_buffer_cap_drops_oldest() -> void:
	transport.default_response = func(_p): return HttpResponse.failed("offline")
	var markers := GamebeastMarkers.new(_context())
	for i in range(520):
		markers.send_marker("e", {"i": i})
	await settle()
	assert_true(markers.buffered_count() <= 500, "capped at 500, got %d" % markers.buffered_count())


func test_keepalive_flush_hands_off_everything() -> void:
	var markers := GamebeastMarkers.new(_context())
	for i in range(12):
		markers._pending.append({"eventName": "e", "markerId": Uuid.v4()})
	var posts: Array = []
	markers._persist_and_flush_keepalive(
		func(url, headers, body): posts.append([url, headers, body])
	)
	assert_eq(posts.size(), 2, "two keepalive batches")
	assert_true(posts[0][0].ends_with("/sdk/v1/markers"), "markers url")
	assert_eq(posts[0][1]["isstudio"], "true", "v1 headers")
	assert_eq(JSON.parse_string(posts[1][2])["markers"].size(), 2, "body is a marker batch")
	assert_true(storage.read_json("markers_development.json") is Array, "persisted as a fallback")


func test_attribution_is_stamped_on_markers() -> void:
	var context := _context()
	context.attribution = {
		"utm": {"source": "x"}, "deeplinkData": {"slug": "s", "interactionId": Uuid.v4()}
	}
	var markers := GamebeastMarkers.new(context)
	markers.send_marker("e")
	markers.flush()
	await settle()
	var marker: Dictionary = _marker_requests()[0].json["markers"][0]
	assert_eq(marker["utm"], {"source": "x"}, "utm")
	assert_eq(marker["deeplinkData"]["slug"], "s", "deeplinkData")
	assert_false(marker["properties"].has("utm"), "attribution not inside properties")
