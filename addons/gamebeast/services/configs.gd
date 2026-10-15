class_name GamebeastConfigs
extends RefCounted
## Remote configurations published from the Gamebeast dashboard, evaluated for the local player.
## Access through [code]Gamebeast.configs[/code].
##
## Values are addressed by dot-path whose first segment is the configuration alias:
## [code]"GameSettings.PlayerSpeed"[/code] reads the [code]PlayerSpeed[/code] key of the
## [code]GameSettings[/code] configuration. Paths reach deeper
## ([code]"GameSettings.UI.Color"[/code]) and index arrays ([code]"GameSettings.Levels.0"[/code]);
## a bare alias returns the whole document.
##
## Configurations load on demand: the first read of an alias fetches it. Aliases listed in the
## setup options (or Project Settings) are also preloaded and gate [signal configs_ready]. Every
## configuration is cached under user:// and refreshed on an interval with hash-based caching.
##
## Note: Godot's JSON parser reads every number as a float. [method get_int] converts for you;
## [method get_value] returns the raw float.

## Emitted once every preloaded configuration is available (from cache or the network).
signal configs_ready
## Emitted after a configuration's values changed (including its first load).
signal configuration_updated(alias: String)

const ApiClient := preload("../internal/api_client.gd")
const Constants := preload("../internal/constants.gd")
const Context := preload("../internal/context.gd")
const EvaluationContext := preload("../internal/evaluation_context.gd")
const Log := preload("../internal/log.gd")
const Storage := preload("../internal/storage.gd")


class ConfigState:
	extends RefCounted
	signal finished

	var alias: String
	var values: Dictionary = {}
	var hash: String = ""
	var loaded := false
	var in_flight := false
	var required := false


class Listener:
	extends RefCounted
	var key: String
	var segments: PackedStringArray
	var include_initial: bool
	var subscription: GamebeastSubscription


class Latch:
	extends RefCounted
	signal done
	var remaining: int

	func _init(count: int) -> void:
		remaining = count

	func count_down() -> void:
		remaining -= 1
		if remaining == 0:
			done.emit()


## Called with the assignments echoed on each evaluated response: (alias, experiments Array).
var assignments_reporter: Callable

var _context: Context
## Lowercased alias -> ConfigState
var _configs: Dictionary = {}
var _listeners: Array = []
var _ready_callbacks: Array = []
var _is_ready := false
var _since_refresh := 0.0
var _since_unloaded_retry := 0.0
var _identity_generation := 0
var _stopped := false


func _init(context: Context) -> void:
	_context = context
	for alias in context.options.configurations:
		if alias.strip_edges() != "":
			_register(alias.strip_edges(), true)
	_check_ready()


## True once every preloaded configuration is available. Lazily loaded ones don't count.
func is_ready() -> bool:
	return _is_ready


## The value at [param path], or [param default] when missing or not loaded yet. Dictionaries and
## arrays are returned as copies.
func get_value(path: String, default: Variant = null) -> Variant:
	var found := _lookup(path, true)
	if not found[0] or found[1] == null:
		return default
	var value: Variant = found[1]
	return value.duplicate(true) if value is Dictionary or value is Array else value


## {"found": bool, "value": Variant}. Doesn't log when the value is missing.
func try_get(path: String) -> Dictionary:
	var found := _lookup(path, false)
	var value: Variant = found[1]
	if value is Dictionary or value is Array:
		value = value.duplicate(true)
	return {"found": found[0] and value != null, "value": value}


func has_value(path: String) -> bool:
	return try_get(path)["found"]


func get_int(path: String, default: int = 0) -> int:
	var value: Variant = get_value(path)
	match typeof(value):
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value) if is_finite(value) else default
		TYPE_STRING:
			return value.to_int() if value.is_valid_int() else default
		_:
			return default


func get_float(path: String, default: float = 0.0) -> float:
	var value: Variant = get_value(path)
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return value.to_float() if value.is_valid_float() else default
		_:
			return default


func get_bool(path: String, default: bool = false) -> bool:
	var value: Variant = get_value(path)
	if value is bool:
		return value
	if value is String and value.to_lower() in ["true", "false"]:
		return value.to_lower() == "true"
	return default


func get_string(path: String, default: String = "") -> String:
	var value: Variant = get_value(path)
	match typeof(value):
		TYPE_STRING:
			return value
		TYPE_FLOAT:
			return str(int(value)) if value == floorf(value) and absf(value) < 1e15 else str(value)
		TYPE_INT, TYPE_BOOL:
			return str(value)
		_:
			return default


func get_dict(path: String, default: Dictionary = {}) -> Dictionary:
	var value: Variant = get_value(path)
	return value if value is Dictionary else default


func get_array(path: String, default: Array = []) -> Array:
	var value: Variant = get_value(path)
	return value if value is Array else default


## Call [param callback] once every preloaded configuration is ready (right away if already
## ready). The subscription cancels itself after firing.
func on_ready(callback: Callable) -> GamebeastSubscription:
	var subscription := GamebeastSubscription.new(callback)
	if _is_ready:
		callback.call()
		subscription.cancel()
	else:
		_ready_callbacks.append(subscription)
	return subscription


## Call [param callback] with the new value whenever the value at [param path] changes. Doesn't
## fire for the initial load; use [method observe] for that.
func on_changed(path: String, callback: Callable) -> GamebeastSubscription:
	return _add_listener(path, callback, false)


## Call [param callback] with the current value as soon as it is available, then with the new
## value on every change. The best fit for lazily loaded configurations.
func observe(path: String, callback: Callable) -> GamebeastSubscription:
	var subscription := _add_listener(path, callback, true)
	if subscription == null:
		return null
	var split := _split(path)
	var state: ConfigState = _configs.get(split[0].to_lower())
	if state != null and state.loaded:
		callback.call(_copy(_resolve(state.values, split[1])))
	return subscription


## Coroutine. Refresh every known configuration now (in addition to the background refresh).
func refresh() -> void:
	_since_refresh = 0.0
	var states := _configs.values()
	if states.is_empty():
		return
	var latch := Latch.new(states.size())
	for state in states:
		_refresh_counted(state, latch)
	if latch.remaining > 0:
		await latch.done


## Aliases the SDK is tracking (preloaded and lazily loaded).
func get_known_aliases() -> PackedStringArray:
	var aliases := PackedStringArray()
	for state in _configs.values():
		aliases.append(state.alias)
	return aliases


# --- Internal (called by the Gamebeast autoload) -----------------------------------------------


func _start() -> void:
	refresh()


func _tick(delta: float) -> void:
	if _stopped or _configs.is_empty():
		return
	_since_unloaded_retry += delta
	if _since_unloaded_retry >= Constants.CONFIG_UNLOADED_RETRY_SEC:
		_since_unloaded_retry = 0.0
		for state in _configs.values():
			if not state.loaded and not state.in_flight:
				_refresh_state(state)
	var interval := _context.settings.config_refresh_interval_sec
	if interval <= 0.0:
		return
	_since_refresh += delta
	if _since_refresh >= interval:
		refresh()


func _on_resumed() -> void:
	if not _configs.is_empty():
		refresh()


## Evaluated content is per player: discard in-flight responses, drop hashes so every config
## refetches in full, and refresh for the new player. Current values keep serving meanwhile.
func _on_identity_changed() -> void:
	_identity_generation += 1
	for state in _configs.values():
		state.hash = ""
		_refresh_after_in_flight(state)


func _shutdown() -> void:
	_stopped = true


func _register(alias: String, required: bool) -> ConfigState:
	var key := alias.to_lower()
	if _configs.has(key):
		var existing: ConfigState = _configs[key]
		existing.required = existing.required or required
		return existing
	var state := ConfigState.new()
	state.alias = alias
	state.required = required
	_configs[key] = state
	var cached: Variant = _load_cache(alias)
	if cached is Dictionary:
		_apply(state, cached, false)
		Log.info("Loaded cached configuration '%s' (hash %s)." % [alias, state.hash])
	return state


func _ensure(alias: String) -> ConfigState:
	var key := alias.to_lower()
	if _configs.has(key):
		return _configs[key]
	var state := _register(alias, false)
	Log.info("Configuration '%s' was not preloaded; fetching it on demand." % alias)
	_refresh_state(state)
	return state


func _refresh_counted(state: ConfigState, latch: Latch) -> void:
	await _refresh_state(state)
	latch.count_down()


func _refresh_state(state: ConfigState) -> void:
	if _stopped:
		return
	if state.in_flight:
		await state.finished
		return
	state.in_flight = true
	var generation := _identity_generation
	var result: Dictionary = await _context.api.evaluate_configuration(
		state.alias,
		state.hash,
		_context.distinct_id(),
		EvaluationContext.build(_context.options.user_properties)
	)
	state.in_flight = false
	# The identity changed while this request was in flight: it was evaluated for the previous
	# player, so drop it.
	if generation == _identity_generation and not _stopped:
		match result["status"]:
			ApiClient.FetchStatus.UPDATED:
				_apply(state, result["response"], true)
				Log.info("Configuration '%s' updated (hash %s)." % [state.alias, state.hash])
			ApiClient.FetchStatus.NOT_MODIFIED:
				Log.info("Configuration '%s' unchanged." % state.alias)
			ApiClient.FetchStatus.NOT_FOUND:
				Log.error(
					(
						"Configuration '%s' not found (%s). Check the alias against your dashboard."
						% [state.alias, result["error"]]
					)
				)
			ApiClient.FetchStatus.FAILED:
				Log.warn(
					(
						"Refresh of configuration '%s' failed (%s); will retry."
						% [state.alias, result["error"]]
					)
				)
	state.finished.emit()


func _refresh_after_in_flight(state: ConfigState) -> void:
	if state.in_flight:
		await state.finished
	await _refresh_state(state)


func _apply(state: ConfigState, response: Dictionary, persist: bool) -> void:
	var new_values: Dictionary = {}
	if response.get("configuration") is Dictionary:
		new_values = response["configuration"]
	else:
		Log.warn("Configuration '%s' root is not a JSON object; no values applied." % state.alias)
	var old_values := state.values
	var was_loaded := state.loaded
	state.values = new_values
	state.hash = str(response.get("hash", ""))
	state.loaded = true
	if persist:
		_save_cache(state.alias, response)
	if assignments_reporter.is_valid():
		var experiments: Variant = response.get("experiments", [])
		assignments_reporter.call(state.alias, experiments if experiments is Array else [])
	_notify(state.alias.to_lower(), was_loaded, old_values, new_values)
	if not was_loaded or old_values != new_values:
		configuration_updated.emit(state.alias)
	_check_ready()


func _notify(key: String, was_loaded: bool, old_values: Dictionary, new_values: Dictionary) -> void:
	_listeners = _listeners.filter(func(l): return l.subscription.is_active())
	for listener in _listeners.duplicate():
		if listener.key != key or not listener.subscription.is_active():
			continue
		var new_value: Variant = _resolve(new_values, listener.segments)
		if not was_loaded:
			if listener.include_initial:
				listener.subscription.callback.call(_copy(new_value))
			continue
		var old_value: Variant = _resolve(old_values, listener.segments)
		if typeof(old_value) != typeof(new_value) or old_value != new_value:
			listener.subscription.callback.call(_copy(new_value))


func _add_listener(
	path: String, callback: Callable, include_initial: bool
) -> GamebeastSubscription:
	var split := _split(path)
	if split[0] == "" or not callback.is_valid():
		Log.error('A config subscription needs a path like "Alias.Key" and a valid callable.')
		return null
	_ensure(split[0])
	var listener := Listener.new()
	listener.key = split[0].to_lower()
	listener.segments = split[1]
	listener.include_initial = include_initial
	listener.subscription = GamebeastSubscription.new(callback)
	_listeners.append(listener)
	return listener.subscription


func _check_ready() -> void:
	if _is_ready:
		return
	for state in _configs.values():
		if state.required and not state.loaded:
			return
	_is_ready = true
	configs_ready.emit()
	var callbacks := _ready_callbacks
	_ready_callbacks = []
	for subscription in callbacks:
		if subscription.is_active():
			subscription.callback.call()
			subscription.cancel()


## [found_and_loaded: bool, value]
func _lookup(path: String, log_errors: bool) -> Array:
	var split := _split(path)
	if split[0] == "":
		Log.error("Config read without a valid path (expected \"Alias.Key\"): '%s'." % path)
		return [false, null]
	var state := _ensure(split[0])
	if not state.loaded:
		if log_errors:
			(
				Log
				. warn(
					(
						"Configuration '%s' has not loaded yet; use observe() or the configs_ready signal."
						% split[0]
					)
				)
			)
		return [false, null]
	var value: Variant = _resolve(state.values, split[1])
	return [value != null, value]


## [alias, segments]
static func _split(path: String) -> Array:
	var parts := path.strip_edges().split(".")
	if parts.is_empty() or parts[0].strip_edges() == "":
		return ["", PackedStringArray()]
	return [parts[0].strip_edges(), parts.slice(1)]


static func _resolve(root: Variant, segments: PackedStringArray) -> Variant:
	var current: Variant = root
	for segment in segments:
		if current is Dictionary:
			if not current.has(segment):
				return null
			current = current[segment]
		elif current is Array and segment.is_valid_int():
			var index := segment.to_int()
			if index < 0 or index >= current.size():
				return null
			current = current[index]
		else:
			return null
	return current


static func _copy(value: Variant) -> Variant:
	return value.duplicate(true) if value is Dictionary or value is Array else value


func _cache_file(alias: String) -> String:
	return (
		"configuration_%s_%s.json"
		% [Storage.safe_name(_context.environment_alias), Storage.safe_name(alias)]
	)


## The cache is stamped with the app version, SDK version and distinct id; a mismatch discards it
## (after a game update the SDK waits for fresh values rather than serving the old build's).
func _load_cache(alias: String) -> Variant:
	var stored: Variant = _context.storage.read_json(_cache_file(alias))
	if not (stored is Dictionary):
		return null
	if (
		stored.get("appVersion") != _app_version()
		or stored.get("sdkVersion") != Constants.SDK_VERSION
		or stored.get("distinctId") != _context.distinct_id()
		or not (stored.get("response") is Dictionary)
	):
		return null
	return stored["response"]


func _save_cache(alias: String, response: Dictionary) -> void:
	(
		_context
		. storage
		. write_json(
			_cache_file(alias),
			{
				"appVersion": _app_version(),
				"sdkVersion": Constants.SDK_VERSION,
				"distinctId": _context.distinct_id(),
				"response": response,
			}
		)
	)


static func _app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))
