class_name GamebeastOptions
extends RefCounted
## Setup options for the Gamebeast SDK. Pass to [method Gamebeast.setup], or let the SDK build
## them from Project Settings > Gamebeast when auto-initialize is on.
##
## Interval settings default to -1 ("auto"): a short interval in the editor and debug exports, so
## dashboard edits and markers show up quickly while testing, and a longer one in release exports.
## The SDK clamps out-of-range values and warns.

## Your Gamebeast project SDK key. Required. It is public (it ships in your game build).
var api_key: String = ""

## Optional distinct id for the local player. When empty, the SDK generates an anonymous id on
## first launch and persists it under user://, so the same player is reported across sessions.
var distinct_id: String = ""

## The Gamebeast environment to report to. "auto" (the default) is development in the editor and
## debug exports and production in release exports; "production" or "development" pins it.
## TODO(post-release): custom environments. Coming soon. Until then any other value logs a warning
## and falls back to auto.
var environment: String = "auto"

## Configurations to preload at startup, by alias. Preloaded configurations gate
## [signal GamebeastConfigs.configs_ready]. Others are fetched the first time they are read.
var configurations: PackedStringArray = PackedStringArray()

## Seconds between marker batch sends. -1 = auto (2 s in the editor and debug exports, 10 s in
## release). Minimum 1. Markers are also sent as soon as [member marker_batch_size] are waiting,
## and whenever the game quits or goes to the background.
var marker_flush_interval_sec: float = -1.0

## Send a batch as soon as this many markers are waiting. 1-500, default 100.
var marker_batch_size: int = 100

## Seconds between change checks against the environment's status snapshot, a cached request that
## answers 304 when nothing changed. A changed configuration or experiment is re-evaluated right
## away. -1 = auto (5 s in the editor and debug exports, 60 s in release). 0 disables it. Minimum 5
## otherwise. The backend can ask for a longer interval while shedding load; the SDK honours it.
var status_poll_interval_sec: float = -1.0

## Seconds between full re-evaluations of every configuration, which catch changes the status
## snapshot can't show: this player's own assignment (a manual pin, a rollout ramp). -1 = auto
## (15 s in the editor and debug exports; 120 s in release, or 60 s with status polling off). 0
## disables it. Minimum 10 otherwise.
var config_refresh_interval_sec: float = -1.0

## Custom properties describing the player, sent as targeting context with every configuration
## evaluation (e.g. {"vip": true}). Change them later with [method Gamebeast.set_user_properties].
## Values must be strings, numbers, booleans, null, or arrays of one of those.
var user_properties: Dictionary = {}

## Rotate the session id when the app returns after being backgrounded at least this long.
## 0 keeps one session per app run.
var session_timeout_sec: float = 1800.0

## SDK warnings for API misuse and failed requests (errors always print).
var warnings_enabled: bool = true

## Verbose SDK logging of internal state changes.
var debug_logging: bool = false

## Override the Gamebeast API base URL. Leave empty for production use.
var api_url: String = ""


static func with_api_key(key: String) -> GamebeastOptions:
	var options := GamebeastOptions.new()
	options.api_key = key
	return options


func duplicate_options() -> GamebeastOptions:
	var copy := GamebeastOptions.new()
	for property in get_property_list():
		if property["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var value: Variant = get(property["name"])
			copy.set(property["name"], value.duplicate() if value is Dictionary else value)
	copy.configurations = configurations.duplicate()
	return copy
