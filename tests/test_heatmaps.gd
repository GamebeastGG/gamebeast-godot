extends "res://tests/test_case.gd"

const HeatmapApi := preload("res://addons/gamebeast/editor/heatmap_api.gd")
const OverheadRenderer := preload("res://addons/gamebeast/editor/overhead_renderer.gd")


func test_region_plan_uses_xz_and_clamps_resolution() -> void:
	var small := OverheadRenderer.plan(Vector3(10, 5, -20), Vector3(-10, 0, 30))
	assert_eq(small["min_x"], -10.0, "min x")
	assert_eq(small["max_z"], 30.0, "max z")
	assert_eq(small["resolution"], 1.0, "1 unit per pixel when it fits")
	assert_eq(small["size_px"], Vector2i(20, 50), "pixel size from XZ extent")
	var big := OverheadRenderer.plan(Vector3.ZERO, Vector3(5000, 0, 1000))
	assert_eq(big["resolution"], 3.0, "scaled to stay under 2048 px")
	assert_true(big["size_px"].x <= OverheadRenderer.MAX_PIXELS, "within max pixels")
	var huge := OverheadRenderer.plan(Vector3.ZERO, Vector3(10_000_000, 0, 1))
	assert_eq(huge["resolution"], 255.0, "capped at the backend's 255")


func test_heatmap_api_requests() -> void:
	var transport := FakeTransport.new()
	transport.queued = [
		FakeTransport.json(200, [{"id": "h1", "name": "Map"}, "junk"]),
		FakeTransport.json(200, {"id": "h2"}),
		HttpResponse.of(200, "{}"),
		HttpResponse.of(200, "{}"),
		FakeTransport.json(403, {"errorCode": "FORBIDDEN"}),
	]
	var api := HeatmapApi.new(transport, " key ", "https://api.test/")
	var listed: Dictionary = await api.list()
	assert_eq(listed["heatmaps"], [{"id": "h1", "name": "Map"}], "list parsed, junk dropped")
	var created: Dictionary = await api.create({"name": "New"})
	assert_eq(created["id"], "h2", "created id")
	await api.update("h 2", {"name": "Renamed"})
	await api.upload_image("h2", PackedByteArray([1, 2, 3]))
	var deleted: Dictionary = await api.delete("h2")
	assert_false(deleted["ok"], "403 surfaces as failure")
	var requests: Array = transport.requests
	assert_eq(requests[0].url, "https://api.test/sdk/v1/heatmaps/list", "list url")
	assert_eq(requests[0].method, HTTPClient.METHOD_GET, "list method")
	assert_eq(requests[1].json, {"name": "New"}, "create body")
	assert_eq(requests[2].url, "https://api.test/sdk/v1/heatmaps/h%202", "id is url-encoded")
	assert_eq(requests[2].method, HTTPClient.METHOD_PUT, "update method")
	assert_eq(requests[3].headers["content-type"], "image/png", "raw png upload")
	assert_eq(requests[3].url, "https://api.test/sdk/v1/heatmaps/h2/image", "image url")
	assert_eq(requests[4].method, HTTPClient.METHOD_DELETE, "delete method")
	assert_eq(requests[0].headers["authorization"], "key", "key trimmed")
	assert_eq(requests[0].headers["isstudio"], "true", "editor headers")
