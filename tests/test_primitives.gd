extends "res://tests/test_case.gd"

const ResolvedSettings := preload("res://addons/gamebeast/internal/resolved_settings.gd")

const Attribution := preload("res://addons/gamebeast/internal/attribution.gd")
const Constants := preload("res://addons/gamebeast/internal/constants.gd")
const GbEnvironment := preload("res://addons/gamebeast/internal/environment.gd")
const JsonCodec := preload("res://addons/gamebeast/internal/json_codec.gd")
const Uuid := preload("res://addons/gamebeast/internal/uuid.gd")
const Identity := preload("res://addons/gamebeast/internal/identity.gd")
const ApiClient := preload("res://addons/gamebeast/internal/api_client.gd")


func test_uuid_is_dashed_v4() -> void:
	var seen := {}
	for i in range(50):
		var id := Uuid.v4()
		assert_true(Uuid.is_uuid(id), "not a uuid: " + id)
		assert_eq(id[14], "4", "version nibble")
		assert_true(id[19] in ["8", "9", "a", "b"], "variant nibble: " + id)
		seen[id] = true
	assert_eq(seen.size(), 50, "uuids are unique")


func test_environment_resolution() -> void:
	assert_eq(GbEnvironment.resolve_alias("auto", true), "development", "auto in editor/debug")
	assert_eq(GbEnvironment.resolve_alias("auto", false), "production", "auto in release")
	assert_eq(GbEnvironment.resolve_alias("", false), "production", "empty is auto")
	assert_eq(GbEnvironment.resolve_alias("  ", true), "development", "blank is auto")
	assert_eq(GbEnvironment.resolve_alias("production", true), "production", "explicit in editor")
	assert_eq(GbEnvironment.resolve_alias("development", false), "development", "explicit dev")
	assert_eq(GbEnvironment.resolve_alias("  Staging ", false), "staging", "custom, normalized")
	assert_eq(GbEnvironment.resolve_alias("Studio", false), "development", "studio synonym")
	assert_eq(GbEnvironment.resolve_alias("QA env_1", false), "qa-env1", "backend slug rules")
	assert_eq(GbEnvironment.resolve_alias("!!", false), "", "invalid alias")


func test_isstudio_mapping_matches_js_sdk() -> void:
	assert_true(GbEnvironment.is_studio("development"), "development -> isstudio true")
	assert_false(GbEnvironment.is_studio("production"), "production -> isstudio false")
	assert_true(GbEnvironment.is_studio("staging"), "unsupported -> development")
	assert_false(GbEnvironment.supported_by_v1("staging"), "custom unsupported on v1")


func test_api_client_headers() -> void:
	var api := ApiClient.new(null, "key-1", "production", "https://example.test/")
	api.session_id = "godot-abc"
	assert_eq(api.base_url(), "https://example.test", "trailing slash trimmed")
	var v1 := api.v1_headers()
	assert_eq(v1["authorization"], "key-1", "auth")
	assert_eq(v1["sdkversion"], "gamebeast-godot/" + Constants.SDK_VERSION, "sdkversion")
	assert_eq(v1["isstudio"], "false", "production isstudio")
	assert_eq(v1["serverid"], "godot-abc", "serverid is session")
	assert_eq(v1["universeid"], "0", "universeid")
	assert_false(v1.has("environment"), "no environment header on v1")
	var v2 := api.v2_headers()
	assert_eq(v2["environment"], "production", "environment header")
	assert_false(v2.has("isstudio"), "no isstudio on v2")
	var dev := ApiClient.new(null, "k", "development", "")
	assert_eq(dev.v1_headers()["isstudio"], "true", "development isstudio")
	assert_eq(dev.base_url(), Constants.DEFAULT_API_URL, "default url")


func test_json_codec_converts_godot_types() -> void:
	var result := (
		JsonCodec
		. to_json_value(
			{
				"pos": Vector3(1, 2, 3),
				"pos2": Vector2i(4, 5),
				"color": Color(1, 0, 0, 1),
				"name": &"hero",
				"nested": {"list": [Vector2(1, 2), 3, "x"]},
				"bad": Node,
				"nan": NAN,
			}
		)
	)
	assert_true(result[0], "dictionary converts")
	var value: Dictionary = result[1]
	assert_eq(value["pos"], [1.0, 2.0, 3.0], "Vector3")
	assert_eq(value["pos2"], [4, 5], "Vector2i")
	assert_eq(value["color"], [1.0, 0.0, 0.0, 1.0], "Color")
	assert_eq(value["name"], "hero", "StringName")
	assert_eq(value["nested"]["list"], [[1.0, 2.0], 3, "x"], "nested")
	assert_false(value.has("bad"), "objects dropped")
	assert_false(value.has("nan"), "NaN dropped")


func test_identity_persists_anonymous_id() -> void:
	var storage := fresh_storage()
	var first := Identity.new(storage)
	var second := Identity.new(storage)
	assert_true(Uuid.is_uuid(first.anonymous_id), "anonymous id is a uuid")
	assert_eq(second.anonymous_id, first.anonymous_id, "persisted across launches")
	var explicit := Identity.new(storage, " player-1 ")
	assert_eq(explicit.distinct_id, "player-1", "explicit id wins")
	explicit.explicit_id = ""
	assert_eq(explicit.distinct_id, first.anonymous_id, "reset falls back to anonymous")


func test_attribution_parses_gamebeast_deeplink() -> void:
	var parsed := Attribution.parse(
		"https://game.test/play?utm_source=tiktok&utm_campaign=Summer%20Sale&utm_id=gb_summer#x"
	)
	assert_eq(
		parsed["utm"], {"source": "tiktok", "campaign": "Summer Sale", "id": "gb_summer"}, "utm"
	)
	assert_eq(parsed["deeplinkData"]["slug"], "summer", "slug")
	assert_true(Uuid.is_uuid(parsed["deeplinkData"]["interactionId"]), "interaction id")


func test_attribution_ignores_plain_visits_and_foreign_ids() -> void:
	assert_eq(Attribution.parse("https://game.test/play?level=3"), {}, "no utm")
	assert_eq(Attribution.parse(""), {}, "empty url")
	var foreign := Attribution.parse("https://game.test/?utm_id=abc&utm_medium=cpc")
	assert_false(foreign.has("deeplinkData"), "non-gb utm_id is not a deeplink")
	assert_eq(foreign["utm"]["medium"], "cpc", "utm kept")
	var long_slug := Attribution.parse("https://game.test/?utm_id=gb_" + "a".repeat(129))
	assert_false(long_slug.has("deeplinkData"), "slug over 128 chars rejected")


func test_resolved_settings_auto_and_clamping() -> void:
	var options := GamebeastOptions.new()
	var dev: Variant = ResolvedSettings.resolve(options, true)
	var release: Variant = ResolvedSettings.resolve(options, false)
	assert_eq(dev.marker_flush_interval_sec, 2.0, "dev marker interval")
	assert_eq(release.marker_flush_interval_sec, 10.0, "release marker interval")
	assert_eq(dev.config_refresh_interval_sec, 15.0, "dev refresh interval")
	assert_eq(release.config_refresh_interval_sec, 120.0, "release full refresh with status")
	assert_eq(dev.status_poll_interval_sec, 5.0, "dev status interval")
	assert_eq(release.status_poll_interval_sec, 60.0, "release status interval")
	var no_status := GamebeastOptions.new()
	no_status.status_poll_interval_sec = 0.0
	assert_eq(
		ResolvedSettings.resolve(no_status, false).config_refresh_interval_sec,
		60.0,
		"faster full refresh without status"
	)
	assert_eq(release.marker_batch_size, 100, "default batch size")
	options.marker_flush_interval_sec = 0.1
	options.marker_batch_size = 5000
	options.config_refresh_interval_sec = 0.0
	var custom: Variant = ResolvedSettings.resolve(options, false)
	assert_eq(custom.marker_flush_interval_sec, 1.0, "flush interval floor")
	assert_eq(custom.marker_batch_size, 500, "batch size cap")
	assert_eq(custom.config_refresh_interval_sec, 0.0, "0 disables refresh")
	options.config_refresh_interval_sec = 2.0
	assert_eq(ResolvedSettings.resolve(options, false).config_refresh_interval_sec, 10.0, "floor")
