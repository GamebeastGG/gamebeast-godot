## Turns GamebeastOptions interval settings ("auto" = -1, user values) into the values the SDK runs
## with, clamping out-of-range ones with a warning. Mirrors the Roblox SDK's studio/live defaults.

const Constants := preload("constants.gd")
const Log := preload("log.gd")

var marker_flush_interval_sec: float
var marker_batch_size: int
## 0 = background refresh disabled.
var config_refresh_interval_sec: float
## 0 = status polling disabled.
var status_poll_interval_sec: float


static func resolve(options: GamebeastOptions, is_dev_runtime: bool) -> RefCounted:
	var resolved := new()
	resolved.marker_flush_interval_sec = _interval(
		"marker_flush_interval_sec",
		options.marker_flush_interval_sec,
		(
			Constants.MARKER_FLUSH_INTERVAL_DEV_SEC
			if is_dev_runtime
			else Constants.MARKER_FLUSH_INTERVAL_RELEASE_SEC
		),
		Constants.MARKER_MIN_FLUSH_INTERVAL_SEC,
		false
	)
	resolved.status_poll_interval_sec = _interval(
		"status_poll_interval_sec",
		options.status_poll_interval_sec,
		Constants.STATUS_POLL_DEV_SEC if is_dev_runtime else Constants.STATUS_POLL_RELEASE_SEC,
		Constants.STATUS_POLL_MIN_SEC,
		true
	)
	var refresh_release := (
		Constants.CONFIG_REFRESH_RELEASE_SEC
		if resolved.status_poll_interval_sec > 0.0
		else Constants.CONFIG_REFRESH_RELEASE_NO_STATUS_SEC
	)
	resolved.config_refresh_interval_sec = _interval(
		"config_refresh_interval_sec",
		options.config_refresh_interval_sec,
		Constants.CONFIG_REFRESH_DEV_SEC if is_dev_runtime else refresh_release,
		Constants.CONFIG_MIN_REFRESH_SEC,
		true
	)
	var batch := options.marker_batch_size
	if batch < 1 or batch > Constants.MARKER_MAX_BATCH_SIZE:
		batch = clampi(batch, 1, Constants.MARKER_MAX_BATCH_SIZE)
		Log.warn(
			"marker_batch_size must be 1-%d; using %d." % [Constants.MARKER_MAX_BATCH_SIZE, batch]
		)
	resolved.marker_batch_size = batch
	return resolved


static func _interval(
	name: String, value: float, auto_value: float, minimum: float, zero_disables: bool
) -> float:
	if value < 0.0:
		return auto_value
	if value == 0.0 and zero_disables:
		return 0.0
	if value < minimum:
		Log.warn("%s must be at least %ss; using %ss." % [name, minimum, minimum])
		return minimum
	return value
