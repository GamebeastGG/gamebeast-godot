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


func test_full_batch_flushes_immediately_then_interval() -> void:
	var markers := GamebeastMarkers.new(_context())
	for i in range(250):
		markers.send_marker("e", {"i": i})
	await settle()
	assert_eq(_marker_requests().size(), 2, "two full batches of 100 sent")
	assert_eq(_marker_requests()[0].json["markers"].size(), 100, "default batch size 100")
	assert_eq(markers.buffered_count(), 50, "fifty waiting")
	markers._tick(10.0)
	await settle()
	assert_eq(_marker_requests().size(), 3, "interval flush")
	assert_eq(_marker_requests()[2].json["markers"].size(), 50, "remainder batch")


func test_batch_size_and_interval_are_configurable() -> void:
	var options := GamebeastOptions.with_api_key("key")
	options.marker_batch_size = 3
	options.marker_flush_interval_sec = 30.0
	var markers := GamebeastMarkers.new(Context.new(options, "development", transport, storage))
	for i in range(4):
		markers.send_marker("e")
	await settle()
	assert_eq(_marker_requests().size(), 1, "batch of 3 sent")
	markers._tick(29.0)
	await settle()
	assert_eq(_marker_requests().size(), 1, "custom interval not reached")
	markers._tick(1.5)
	await settle()
	assert_eq(_marker_requests().size(), 2, "custom interval flush")


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


func test_park_and_replay_next_launch_without_resending_in_flight() -> void:
	transport.manual = true
	var context := _context()
	var markers := GamebeastMarkers.new(context)
	markers.send_marker("a")
	markers.send_marker("b")
	markers.flush()  # in flight, never answered (the game is killed); may have arrived
	markers.send_marker("c")
	markers._park()
	assert_eq(markers.buffered_count(), 2, "only the in-flight batch stays in memory")

	var next_transport := FakeTransport.new()
	var next_context := Context.new(
		GamebeastOptions.with_api_key("key"), "development", next_transport, storage
	)
	var restored := GamebeastMarkers.new(next_context)
	assert_eq(restored.buffered_count(), 1, "restored only the unsent marker")
	assert_eq(storage.read_json("markers_development.json"), null, "claimed: file cleared")
	restored._tick(0.1)
	await settle()
	var sent: Array = next_transport.requests_to("/sdk/v1/markers")[0].json["markers"]
	assert_eq(sent.map(func(m): return m["eventName"]), ["c"], "in-flight markers not resent")
	assert_eq(sent[0]["sessionId"], context.session_id, "original session kept")


func test_park_then_resume_sends_once() -> void:
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("a")
	markers._park()
	assert_eq(markers.buffered_count(), 0, "moved to disk")
	markers._resume()
	await settle()
	markers._park()
	markers._resume()
	await settle()
	assert_eq(_marker_requests().size(), 1, "sent exactly once")
	assert_eq(storage.read_json("markers_development.json"), null, "no disk copy left")


func test_cancelled_quit_claims_parked_markers() -> void:
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("a")
	markers._park()
	for i in range(4):
		await tree.process_frame
		markers._tick(0.016)
	await settle()
	assert_eq(_marker_requests().size(), 1, "still running after quit request: sent")


func test_parks_append_to_unclaimed_file() -> void:
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("a")
	markers._park()
	markers.send_marker("b")
	markers._park()
	var stored: Array = storage.read_json("markers_development.json")
	assert_eq(stored.map(func(m): return m["eventName"]), ["a", "b"], "both kept")


func test_park_files_are_per_environment() -> void:
	var markers := GamebeastMarkers.new(_context("production"))
	markers.send_marker("x")
	markers._park()
	assert_true(storage.read_json("markers_production.json") is Array, "production file")
	assert_eq(storage.read_json("markers_development.json"), null, "no development file")


func test_buffer_cap_drops_oldest() -> void:
	transport.default_response = func(_p): return HttpResponse.failed("offline")
	var markers := GamebeastMarkers.new(_context())
	for i in range(520):
		markers.send_marker("e", {"i": i})
	await settle()
	assert_true(markers.buffered_count() <= 500, "capped at 500, got %d" % markers.buffered_count())


func test_keepalive_drain_sends_without_persisting() -> void:
	var markers := GamebeastMarkers.new(_context())
	for i in range(120):
		markers.send_marker("e")
	await settle()  # one batch of 100 already sent normally
	var posts: Array = []
	markers._drain_for_unload(func(url, headers, body): posts.append([url, headers, body]), true)
	assert_eq(posts.size(), 1, "one keepalive batch")
	assert_true(posts[0][0].ends_with("/sdk/v1/markers"), "markers url")
	assert_eq(posts[0][1]["isstudio"], "true", "v1 headers")
	assert_eq(JSON.parse_string(posts[0][2])["markers"].size(), 20, "the waiting markers")
	assert_eq(storage.read_json("markers_development.json"), null, "handed off, not also saved")


func test_keepalive_drain_respects_byte_budget() -> void:
	var markers := GamebeastMarkers.new(_context())
	var big := "x".repeat(1000)
	for i in range(200):
		markers._pending.append({"eventName": "e", "markerId": Uuid.v4(), "p": big})
	var posts: Array = []
	markers._drain_for_unload(func(_u, _h, body): posts.append(body), true)
	var total := 0
	var sent := 0
	for body in posts:
		total += body.to_utf8_buffer().size()
		sent += JSON.parse_string(body)["markers"].size()
	assert_true(total <= 60000, "under the keepalive budget, got %d" % total)
	var stored: Array = storage.read_json("markers_development.json")
	assert_eq(sent + stored.size(), 200, "the rest are saved for later")


func test_keepalive_drain_offline_saves_everything() -> void:
	var markers := GamebeastMarkers.new(_context())
	markers.send_marker("a")
	var posts: Array = []
	markers._drain_for_unload(func(_u, _h, body): posts.append(body), false)
	assert_eq(posts.size(), 0, "nothing sent offline")
	assert_eq(storage.read_json("markers_development.json").size(), 1, "saved")


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
