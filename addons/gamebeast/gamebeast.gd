extends Node
## The Gamebeast SDK entry point, registered as the [code]Gamebeast[/code] autoload by the plugin.
##
## [codeblock]
## func _ready() -> void:
##     Gamebeast.setup("your-sdk-key")  # or configure Project Settings > Gamebeast
##     Gamebeast.markers.send_marker("level_completed", {"level": 3})
##     Gamebeast.configs.observe("GameSettings.PlayerSpeed", func(v): speed = v)
## [/codeblock]
##
## With [code]gamebeast/general/auto_initialize[/code] on and an API key in Project Settings, the
## SDK sets itself up from those settings at startup. A setup() call from your main scene's
## [code]_ready[/code] runs first and wins (auto-initialization is deferred to the end of the
## first frame).

## Emitted when setup() completes.
signal initialized
## Emitted after identify() or reset_identity() changed the effective distinct id.
signal identity_changed(distinct_id: String)

const Attribution := preload("internal/attribution.gd")
const Constants := preload("internal/constants.gd")
const Context := preload("internal/context.gd")
const GbEnvironment := preload("internal/environment.gd")
const HttpTransport := preload("internal/http_transport.gd")
const Log := preload("internal/log.gd")
const Settings := preload("internal/settings.gd")
const Storage := preload("internal/storage.gd")
const WebBridge := preload("internal/web_bridge.gd")

const SDK_VERSION := Constants.SDK_VERSION
## Settings [method update_settings] accepts.
const RUNTIME_SETTINGS: Array[String] = [
	"marker_flush_interval_sec",
	"marker_batch_size",
	"config_refresh_interval_sec",
	"session_timeout_sec",
	"warnings_enabled",
	"debug_logging",
]

## Analytics markers. Null until setup().
var markers: GamebeastMarkers:
	get:
		return _service(_markers, "markers")
## Remote configurations. Null until setup().
var configs: GamebeastConfigs:
	get:
		return _service(_configs, "configs")
## Experiment assignments. Null until setup().
var experiments: GamebeastExperiments:
	get:
		return _service(_experiments, "experiments")
## Cohort membership. Null until setup().
var cohorts: GamebeastCohorts:
	get:
		return _service(_cohorts, "cohorts")

var _context: Context
var _markers: GamebeastMarkers
var _configs: GamebeastConfigs
var _experiments: GamebeastExperiments
var _cohorts: GamebeastCohorts
var _transport: Variant
var _web: WebBridge
var _backgrounded := false
var _backgrounded_at := 0.0
## Marker services from shut-down sessions whose final sends are still in flight.
var _draining: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Settings.auto_initialize_enabled() and not Engine.is_editor_hint():
		_auto_initialize.call_deferred()


func _process(delta: float) -> void:
	if not _draining.is_empty():
		_draining = _draining.filter(func(m): return m.buffered_count() > 0)
	if _context == null:
		return
	_markers._tick(delta)
	_configs._tick(delta)


func _notification(what: int) -> void:
	if _context == null:
		return
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			# The game may quit right after this and a send couldn't finish, so unsent markers go
			# to disk for the next launch (taken back if the game cancels the quit).
			_markers._park()
		NOTIFICATION_APPLICATION_PAUSED:
			_on_backgrounded()
		NOTIFICATION_APPLICATION_RESUMED:
			_on_foregrounded()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_markers.flush()
		NOTIFICATION_EXIT_TREE:
			shutdown()


## Initialize the SDK with an API key (String), a [GamebeastOptions], or a Dictionary of option
## names to values (e.g. {"api_key": "...", "configurations": ["GameSettings"]}). Ignored with a
## warning when already initialized; call [method shutdown] first to reconfigure.
func setup(options: Variant) -> void:
	_setup_internal(_to_options(options), null, null)


func is_initialized() -> bool:
	return _context != null


## The effective distinct id: the id from options or identify(), or the persisted anonymous id.
## Empty before setup().
func get_distinct_id() -> String:
	return _context.distinct_id() if _context != null else ""


## The resolved environment alias ("production", "development" or a custom alias).
func get_environment() -> String:
	return _context.environment_alias if _context != null else ""


func get_session_id() -> String:
	return _context.session_id if _context != null else ""


## Switch the local player's distinct id (e.g. after login). Configurations are re-evaluated for
## the new player right away. Markers recorded earlier keep the id they were recorded under. The
## id isn't persisted: call identify() again on the next launch (or pass distinct_id to setup).
func identify(distinct_id: String) -> void:
	if not _require_initialized("identify"):
		return
	var id := distinct_id.strip_edges()
	if id == "":
		Log.error("identify called with an empty distinct id; use reset_identity() to log out.")
		return
	_set_identity(id)


## Revert to the device's persisted anonymous id (e.g. after logout).
func reset_identity() -> void:
	if _require_initialized("reset_identity"):
		_set_identity("")


## Replace the custom player properties sent as targeting context (see
## [member GamebeastOptions.user_properties]). Configurations, and so experiment assignments,
## are re-evaluated right away, so a targeted experiment can enroll the player this session.
func set_user_properties(properties: Dictionary) -> void:
	if not _require_initialized("set_user_properties"):
		return
	if properties == _context.options.user_properties:
		return
	_context.options.user_properties = properties.duplicate(true)
	_configs.refresh()


## Set (or with null, remove) one custom player property. See [method set_user_properties].
func set_user_property(key: String, value: Variant) -> void:
	if not _require_initialized("set_user_property"):
		return
	var properties := _context.options.user_properties.duplicate(true)
	if value == null:
		properties.erase(key)
	else:
		properties[key] = value
	set_user_properties(properties)


## The custom player properties currently sent as targeting context.
func get_user_properties() -> Dictionary:
	return _context.options.user_properties.duplicate(true) if _context != null else {}


## Change runtime settings without re-initializing. Accepts a Dictionary with any of
## marker_flush_interval_sec, marker_batch_size, config_refresh_interval_sec,
## session_timeout_sec, warnings_enabled and debug_logging. Omitted
## ones keep their value. The API key, environment and URL are fixed at setup (data already loaded
## is keyed to them).
func update_settings(settings: Dictionary) -> void:
	if not _require_initialized("update_settings"):
		return
	for key in settings:
		var name := str(key)
		if not name in RUNTIME_SETTINGS:
			(
				Log
				. warn(
					(
						"update_settings: '%s' can't be changed at runtime (use shutdown() and setup())."
						% name
					)
				)
			)
			continue
		_context.options.set(name, settings[key])
	Log.warnings_enabled = _context.options.warnings_enabled
	Log.debug_enabled = _context.options.debug_logging
	_context.resolve_settings()


## Send pending markers and tear the SDK down. setup() may be called again afterwards.
func shutdown() -> void:
	if _context == null:
		return
	_markers._shutdown()
	_configs._shutdown()
	# Keep the marker service alive until its final sends complete (their coroutines need it).
	if _markers.buffered_count() > 0:
		_draining.append(_markers)
	if _web != null:
		_web.detach()
		_web = null
	_transport = null
	_context = null
	_markers = null
	_configs = null
	_experiments = null
	_cohorts = null
	_backgrounded = false


# --- Internal ------------------------------------------------------------------------------------


func _auto_initialize() -> void:
	if _context != null:
		return
	var options := Settings.to_options()
	if options.api_key == "":
		Log.warn("Auto-initialize is on but gamebeast/general/api_key is empty; skipping setup.")
		return
	Log.info("Auto-initializing from Project Settings.")
	_setup_internal(options, null, null)


## Test seam: inject a transport and a storage directory.
func _setup_internal(options: GamebeastOptions, transport: Variant, storage: Storage) -> void:
	if _context != null:
		Log.warn("setup() called while already initialized; ignored. Call shutdown() first.")
		return
	if options == null:
		return
	if options.api_key.strip_edges() == "":
		Log.error("setup() requires an API key.")
		return
	Log.debug_enabled = options.debug_logging
	Log.warnings_enabled = options.warnings_enabled
	var alias := GbEnvironment.resolve_alias(
		options.environment, options.custom_environment, GbEnvironment.is_dev_runtime()
	)
	if not GbEnvironment.supported_by_v1(alias):
		# TODO(post-release): custom environments.
		(
			Log
			. warn(
				(
					(
						"Environment '%s': configurations and experiments use it, but markers and cohorts "
						+ "can only target production or development and will be sent to development."
					)
					% alias
				)
			)
		)
	_transport = transport if transport != null else HttpTransport.new(self)
	_context = Context.new(
		options, alias, _transport, storage if storage != null else Storage.new()
	)
	_markers = GamebeastMarkers.new(_context)
	_experiments = GamebeastExperiments.new(_context)
	_configs = GamebeastConfigs.new(_context)
	_configs.assignments_reporter = _experiments._report
	_cohorts = GamebeastCohorts.new(_context)
	_attach_web()
	Log.info(
		(
			"Initialized (environment %s, distinct id %s, SDK %s)."
			% [alias, _context.distinct_id(), Constants.SDK_VERSION_HEADER]
		)
	)
	_configs._start()
	initialized.emit()


func _attach_web() -> void:
	if not WebBridge.is_web():
		return
	_web = WebBridge.new()
	_web.attach()
	_web.hidden.connect(_on_web_hidden)
	_web.visible.connect(_on_foregrounded)
	_web.online.connect(_on_web_online)
	_context.attribution = Attribution.parse(_web.location_href())


func _on_web_hidden() -> void:
	if _context == null:
		return
	if not _backgrounded:
		_backgrounded = true
		_backgrounded_at = Time.get_ticks_msec() / 1000.0
	_markers._drain_for_unload(_web.keepalive_post, _web.is_online())


## Markers saved while offline go out once the browser is back online.
func _on_web_online() -> void:
	if _context != null:
		_markers._resume()


func _on_backgrounded() -> void:
	_backgrounded = true
	_backgrounded_at = Time.get_ticks_msec() / 1000.0
	# Mobile apps can be killed while paused; markers wait on disk and go out on resume.
	_markers._park()


func _on_foregrounded() -> void:
	if _context == null:
		return
	if _backgrounded:
		var away := Time.get_ticks_msec() / 1000.0 - _backgrounded_at
		var timeout := _context.options.session_timeout_sec
		if timeout > 0.0 and away >= timeout:
			_context.rotate_session()
			Log.info("Session rotated after %ds in the background." % int(away))
	_backgrounded = false
	_markers._resume()
	_configs._on_resumed()


func _set_identity(explicit_id: String) -> void:
	var before := _context.distinct_id()
	_context.identity.explicit_id = explicit_id
	if _context.distinct_id() == before:
		return
	_experiments._on_identity_changed()
	_configs._on_identity_changed()
	identity_changed.emit(_context.distinct_id())


func _require_initialized(method: String) -> bool:
	if _context == null:
		Log.error("Gamebeast.%s() called before setup()." % method)
		return false
	return true


func _service(service: Variant, name: String) -> Variant:
	if service == null:
		Log.error("Gamebeast.%s is unavailable until setup() is called." % name)
	return service


static func _to_options(value: Variant) -> GamebeastOptions:
	if value is GamebeastOptions:
		return value.duplicate_options()
	if value is String or value is StringName:
		return GamebeastOptions.with_api_key(str(value).strip_edges())
	if value is Dictionary:
		var options := GamebeastOptions.new()
		for key in value:
			if not str(key) in options:
				Log.warn("Unknown setup option '%s' ignored." % key)
				continue
			if str(key) == "configurations":
				options.configurations = PackedStringArray(value[key])
			else:
				options.set(str(key), value[key])
		return options
	Log.error("setup() expects an API key, a GamebeastOptions or a Dictionary.")
	return null
