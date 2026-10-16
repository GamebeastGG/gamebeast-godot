## Project Settings under `gamebeast/`. Registered by the editor plugin (so they show in
## Project Settings > Gamebeast) and read by the autoload for auto-initialization.

const PREFIX := "gamebeast/"

const API_KEY := PREFIX + "general/api_key"
const ENVIRONMENT := PREFIX + "general/environment"
const CONFIGURATIONS := PREFIX + "general/configurations"
const AUTO_INITIALIZE := PREFIX + "general/auto_initialize"
const MARKER_FLUSH_INTERVAL := PREFIX + "advanced/marker_flush_interval_sec"
const MARKER_BATCH_SIZE := PREFIX + "advanced/marker_batch_size"
const STATUS_POLL_INTERVAL := PREFIX + "advanced/status_poll_interval_sec"
const CONFIG_REFRESH_INTERVAL := PREFIX + "advanced/config_refresh_interval_sec"
const SESSION_TIMEOUT := PREFIX + "advanced/session_timeout_sec"
const WARNINGS_ENABLED := PREFIX + "advanced/warnings_enabled"
const DEBUG_LOGGING := PREFIX + "advanced/debug_logging"
const API_URL := PREFIX + "advanced/api_url"


## [name, default, type, hint, hint_string, basic]
static func definitions() -> Array:
	return [
		[API_KEY, "", TYPE_STRING, PROPERTY_HINT_NONE, "", true],
		# "production" or "development"; blank resolves from the runtime.
		# TODO(post-release): custom environments. Custom environments are coming soon; until
		# then any other value warns at setup and is resolved as if blank.
		[
			ENVIRONMENT,
			"",
			TYPE_STRING,
			PROPERTY_HINT_PLACEHOLDER_TEXT,
			"Blank: development in editor/debug, production in release",
			true
		],
		[
			CONFIGURATIONS,
			PackedStringArray(),
			TYPE_PACKED_STRING_ARRAY,
			PROPERTY_HINT_NONE,
			"",
			true
		],
		[AUTO_INITIALIZE, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", true],
		# -1 = auto: short in the editor and debug exports, longer in release.
		[MARKER_FLUSH_INTERVAL, -1.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "-1,300,1,suffix:s", false],
		[MARKER_BATCH_SIZE, 100, TYPE_INT, PROPERTY_HINT_RANGE, "1,500,1", false],
		# -1 = auto, 0 = off.
		[STATUS_POLL_INTERVAL, -1.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "-1,3600,1,suffix:s", false],
		[
			CONFIG_REFRESH_INTERVAL,
			-1.0,
			TYPE_FLOAT,
			PROPERTY_HINT_RANGE,
			"-1,3600,1,suffix:s",
			false
		],
		[SESSION_TIMEOUT, 1800.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,86400,1,suffix:s", false],
		[WARNINGS_ENABLED, true, TYPE_BOOL, PROPERTY_HINT_NONE, "", false],
		[DEBUG_LOGGING, false, TYPE_BOOL, PROPERTY_HINT_NONE, "", false],
		[
			API_URL,
			"",
			TYPE_STRING,
			PROPERTY_HINT_PLACEHOLDER_TEXT,
			"https://api.gamebeast.gg",
			false
		],
	]


static func register() -> void:
	for definition in definitions():
		var name: String = definition[0]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, definition[1])
		ProjectSettings.set_initial_value(name, definition[1])
		ProjectSettings.add_property_info(
			{
				"name": name,
				"type": definition[2],
				"hint": definition[3],
				"hint_string": definition[4]
			}
		)
		ProjectSettings.set_as_basic(name, definition[5])


static func unregister() -> void:
	for definition in definitions():
		var name: String = definition[0]
		# Only remove untouched settings so disabling the plugin never loses a configured key.
		if ProjectSettings.has_setting(name) and ProjectSettings.get_setting(name) == definition[1]:
			ProjectSettings.set_setting(name, null)


static func auto_initialize_enabled() -> bool:
	return bool(ProjectSettings.get_setting(AUTO_INITIALIZE, true))


static func to_options() -> GamebeastOptions:
	var options := GamebeastOptions.new()
	options.api_key = str(ProjectSettings.get_setting(API_KEY, "")).strip_edges()
	options.environment = str(ProjectSettings.get_setting(ENVIRONMENT, ""))
	options.configurations = PackedStringArray(
		ProjectSettings.get_setting(CONFIGURATIONS, PackedStringArray())
	)
	options.marker_flush_interval_sec = float(
		ProjectSettings.get_setting(MARKER_FLUSH_INTERVAL, -1.0)
	)
	options.marker_batch_size = int(ProjectSettings.get_setting(MARKER_BATCH_SIZE, 100))
	options.status_poll_interval_sec = float(
		ProjectSettings.get_setting(STATUS_POLL_INTERVAL, -1.0)
	)
	options.config_refresh_interval_sec = float(
		ProjectSettings.get_setting(CONFIG_REFRESH_INTERVAL, -1.0)
	)
	options.session_timeout_sec = float(ProjectSettings.get_setting(SESSION_TIMEOUT, 1800.0))
	options.warnings_enabled = bool(ProjectSettings.get_setting(WARNINGS_ENABLED, true))
	options.debug_logging = bool(ProjectSettings.get_setting(DEBUG_LOGGING, false))
	options.api_url = str(ProjectSettings.get_setting(API_URL, ""))
	return options
