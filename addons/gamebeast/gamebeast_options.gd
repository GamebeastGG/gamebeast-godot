class_name GamebeastOptions
extends RefCounted
## Setup options for the Gamebeast SDK. Pass to [method Gamebeast.setup], or let the SDK build
## them from Project Settings > Gamebeast when auto-initialize is on.

enum EnvironmentMode { AUTO = 0, PRODUCTION = 1, DEVELOPMENT = 2 }

## Your Gamebeast project SDK key. Required. It is public (it ships in your game build).
var api_key: String = ""

## Optional distinct id for the local player. When empty, the SDK generates an anonymous id on
## first launch and persists it under user://, so the same player is reported across sessions.
var distinct_id: String = ""

## Which Gamebeast environment to target. AUTO resolves to development in the editor and in debug
## exports, and to production in release exports.
var environment: EnvironmentMode = EnvironmentMode.AUTO

## Optional: target an environment by its alias (e.g. "staging"). Takes precedence over
## [member environment] when set.
## TODO(post-release): custom environments. Coming soon: markers and cohorts can only address
## production and development until then.
var custom_environment: String = ""

## Configurations to preload at startup, by alias. Preloaded configurations gate
## [signal GamebeastConfigs.ready]. Others are fetched the first time they are read.
var configurations: PackedStringArray = PackedStringArray()

## How often (seconds) to re-check the backend for configuration changes. 0 disables background
## refresh ([method GamebeastConfigs.refresh] still works).
var config_refresh_interval_sec: float = 60.0

## Custom properties describing the player, sent as targeting context with every configuration
## evaluation (e.g. {"vip": true}). Read live on every refresh. Values must be strings, numbers,
## booleans, null, or arrays of one of those.
var user_properties: Dictionary = {}

## Rotate the session id when the app returns after being backgrounded at least this long.
## 0 keeps one session per app run.
var session_timeout_sec: float = 1800.0

## Verbose SDK logging.
var debug_logging: bool = false

## Override the Gamebeast API base URL. Leave empty for production use.
var api_url: String = ""


static func with_api_key(key: String) -> GamebeastOptions:
	var options := GamebeastOptions.new()
	options.api_key = key
	return options


func duplicate_options() -> GamebeastOptions:
	var copy := GamebeastOptions.new()
	copy.api_key = api_key
	copy.distinct_id = distinct_id
	copy.environment = environment
	copy.custom_environment = custom_environment
	copy.configurations = configurations.duplicate()
	copy.config_refresh_interval_sec = config_refresh_interval_sec
	copy.user_properties = user_properties
	copy.session_timeout_sec = session_timeout_sec
	copy.debug_logging = debug_logging
	copy.api_url = api_url
	return copy
