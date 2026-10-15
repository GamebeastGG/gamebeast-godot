extends "res://tests/test_case.gd"

const Context := preload("res://addons/gamebeast/internal/context.gd")

var transport: FakeTransport


func before_each() -> void:
	transport = FakeTransport.new()


func _cohorts(alias: String = "production") -> GamebeastCohorts:
	var options := GamebeastOptions.with_api_key("key")
	options.distinct_id = "player-1"
	return GamebeastCohorts.new(Context.new(options, alias, transport, fresh_storage()))


static func membership(is_member: bool, exists: bool = true) -> HttpResponse:
	return FakeTransport.json(
		200, {"cohortExists": exists, "users": [{"userId": "player-1", "isMember": is_member}]}
	)


func test_request_shape_and_result() -> void:
	transport.queued = [membership(true)]
	var cohorts := _cohorts()
	var result: bool = await cohorts.is_member("whales")
	assert_true(result, "member")
	var request = transport.requests[0]
	assert_true(request.url.ends_with("/sdk/v1/cohorts/membership"), "url")
	assert_eq(request.json, {"cohortName": "whales", "userIds": ["player-1"]}, "body")
	assert_eq(request.headers["isstudio"], "false", "production isstudio")


func test_cached_for_sixty_seconds() -> void:
	transport.queued = [membership(true), membership(false)]
	var cohorts := _cohorts()
	await cohorts.is_member("whales")
	var again: bool = await cohorts.is_member("whales")
	assert_true(again, "served from cache")
	assert_eq(transport.requests.size(), 1, "one request")
	cohorts.clear_cache()
	var fresh: bool = await cohorts.is_member("whales")
	assert_false(fresh, "refetched after clear")


func test_concurrent_checks_share_request() -> void:
	transport.manual = true
	var cohorts := _cohorts()
	var results: Array = []
	var check := func(): results.append(await cohorts.is_member("whales"))
	check.call()
	check.call()
	await settle()
	assert_eq(transport.waiting_count(), 1, "single flight")
	transport.resolve(membership(true))
	await settle()
	assert_eq(results, [true, true], "both callers resolved")


func test_failures_and_missing_cohorts_are_false() -> void:
	transport.queued = [
		HttpResponse.failed("offline"), membership(false, false), FakeTransport.json(500, {})
	]
	var cohorts := _cohorts()
	assert_false(await cohorts.is_member("a"), "transport error")
	assert_false(await cohorts.is_member("b"), "missing cohort")
	assert_false(await cohorts.is_member("c"), "server error")
	assert_false(await cohorts.is_member(" "), "empty name, no request")
	assert_eq(transport.requests.size(), 3, "three requests")
