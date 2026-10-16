class_name GamebeastMarkers
extends RefCounted
## Sends engagement markers (analytics events) to Gamebeast. Access through
## [code]Gamebeast.markers[/code].
##
## Markers are batched: a batch is sent once [member GamebeastOptions.marker_batch_size] markers
## are waiting (default 100) or every [member GamebeastOptions.marker_flush_interval_sec] (2 s in
## the editor and debug exports, 10 s in release). Failed sends retry with exponential backoff
## (honouring [code]retry-after[/code]); permanent rejections (4xx) are dropped.
##
## The backend does not deduplicate markers, so a marker lives in exactly one place at a time:
## memory, an in-flight request, or the user:// file. When the game quits or goes to the
## background, unsent markers move to the file; they are claimed back (read and cleared) and sent
## when the game returns or on the next launch. A request still in flight when the process is
## killed is not resent: it may have arrived, and resending could count it twice.

const Constants := preload("../internal/constants.gd")
const Context := preload("../internal/context.gd")
const HttpResponse := preload("../internal/http_response.gd")
const JsonCodec := preload("../internal/json_codec.gd")
const Log := preload("../internal/log.gd")
const Storage := preload("../internal/storage.gd")
const Uuid := preload("../internal/uuid.gd")

## {"markers":[]} around a batch.
const BATCH_WRAPPER_BYTES := 14

var _context: Context
var _pending: Array = []
## Failed batches awaiting resend: {"markers": Array, "attempt": int, "wait": float}
var _retries: Array = []
## Batches currently being sent, by batch id.
var _in_flight: Dictionary = {}
var _next_batch_id := 0
var _since_flush := 0.0
var _stopped := false
## Process frame at which unsent markers were parked on disk, or -1. If the game is still running
## a few frames later (a cancelled quit), they are claimed back.
var _parked_frame := -1


func _init(context: Context) -> void:
	_context = context
	_claim_parked()


## Send a marker attributed to the local player. [param properties] is a Dictionary of
## JSON-friendly values; Vector2/Vector3/Color and other math types are sent as arrays.
func send_marker(marker_type: String, properties: Dictionary = {}) -> void:
	if _stopped:
		Log.warn("send_marker('%s') called after shutdown; marker dropped." % marker_type)
		return
	if marker_type.strip_edges() == "":
		Log.error("send_marker called without a marker type; marker dropped.")
		return
	var converted := JsonCodec.to_json_value(properties, marker_type)
	var marker := {
		"markerId": Uuid.v4(),
		"timestamp": int(Time.get_unix_time_from_system() * 1000.0),
		"eventName": marker_type,
		"distinctId": _context.distinct_id(),
		"sessionId": _context.session_id,
		"properties": converted[1] if converted[0] else {},
	}
	if _context.attribution.has("utm"):
		marker["utm"] = _context.attribution["utm"]
	if _context.attribution.has("deeplinkData"):
		marker["deeplinkData"] = _context.attribution["deeplinkData"]
	_pending.append(marker)
	_enforce_cap()
	if _pending.size() >= _context.settings.marker_batch_size:
		flush()


## Send a marker with a world position in the reserved [code]position[/code] property, which
## heatmaps read. A Vector3 is sent as [x, y, z]. A Vector2 (2D games) is sent as [x, 0, y], so
## 2D positions land on the heatmap's XZ plane.
func send_position(marker_type: String, position: Variant, properties: Dictionary = {}) -> void:
	var with_position := properties.duplicate()
	match typeof(position):
		TYPE_VECTOR3, TYPE_VECTOR3I:
			with_position["position"] = [position.x, position.y, position.z]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			with_position["position"] = [position.x, 0.0, position.y]
		_:
			Log.error(
				"send_position expects a Vector2 or Vector3; marker '%s' dropped." % marker_type
			)
			return
	send_marker(marker_type, with_position)


## Send everything waiting now, including batches waiting out a retry backoff.
func flush() -> void:
	_since_flush = 0.0
	var size: int = _context.settings.marker_batch_size
	while not _pending.is_empty():
		var batch := _pending.slice(0, size)
		_pending = _pending.slice(size)
		_send_batch(batch, 1)


## Number of markers not yet confirmed by the backend (pending, retrying or in flight).
func buffered_count() -> int:
	return _unsent_count() + _in_flight_count()


# --- Internal (called by the Gamebeast autoload) -----------------------------------------------


func _tick(delta: float) -> void:
	if _stopped:
		return
	if _parked_frame >= 0 and Engine.get_process_frames() > _parked_frame + 2:
		# Still running after a quit request (the game cancelled it): take the markers back.
		_claim_parked()
	_tick_retries(delta)
	if _pending.is_empty():
		_since_flush = 0.0
		return
	_since_flush += delta
	if _since_flush >= _context.settings.marker_flush_interval_sec:
		flush()


## Quit or backgrounding: move every unsent marker to disk. In-flight requests carry on.
func _park() -> void:
	var unsent := _take_unsent()
	if unsent.is_empty():
		return
	_write_parked(unsent)
	_parked_frame = Engine.get_process_frames()


## Back in the foreground (or a cancelled quit): claim parked markers and send them.
func _resume() -> void:
	_claim_parked()
	_flush_retries_now()
	flush()


## Web page hide: hand what fits in the browser's keepalive budget to keepalive fetches (they
## outlive the page) and park the rest. Nothing is sent while offline.
func _drain_for_unload(post: Callable, online: bool) -> void:
	var unsent := _take_unsent()
	var leftover: Array = []
	if online:
		var remaining := Constants.KEEPALIVE_MAX_BYTES
		var batch: Array = []
		var batch_bytes := 0
		for marker in unsent:
			var cost := JsonCodec.stringify(marker).to_utf8_buffer().size() + 1
			if batch.is_empty():
				cost += BATCH_WRAPPER_BYTES
			if not leftover.is_empty() or batch_bytes + cost > remaining:
				leftover.append(marker)
				continue
			batch.append(marker)
			batch_bytes += cost
			if batch.size() >= _context.settings.marker_batch_size:
				remaining -= _post_keepalive(post, batch)
				batch = []
				batch_bytes = 0
		if not batch.is_empty():
			_post_keepalive(post, batch)
	else:
		leftover = unsent
	if not leftover.is_empty():
		_write_parked(leftover)
		_parked_frame = -1  # The page stays alive while hidden; claimed back when visible.


func _shutdown() -> void:
	_flush_retries_now()
	flush()
	_stopped = true


func _post_keepalive(post: Callable, batch: Array) -> int:
	var request: Dictionary = _context.api.markers_request(batch)
	post.call(request["url"], request["headers"], request["body"])
	return request["body"].to_utf8_buffer().size()


func _file_name() -> String:
	return "markers_%s.json" % Storage.safe_name(_context.environment_alias)


## Remove and return everything not yet handed to the network.
func _take_unsent() -> Array:
	var unsent: Array = []
	for entry in _retries:
		unsent.append_array(entry["markers"])
	unsent.append_array(_pending)
	_retries.clear()
	_pending = []
	return unsent


## Append to the parked file (an earlier park may not have been claimed yet), keeping the newest.
func _write_parked(markers: Array) -> void:
	var stored: Variant = _context.storage.read_json(_file_name())
	var merged: Array = _valid_markers(stored) + markers
	if merged.size() > Constants.MARKER_MAX_BUFFERED:
		Log.error(
			(
				"Marker storage full; dropped the %d oldest marker(s)."
				% (merged.size() - Constants.MARKER_MAX_BUFFERED)
			)
		)
		merged = merged.slice(merged.size() - Constants.MARKER_MAX_BUFFERED)
	if not _context.storage.write_json(_file_name(), merged):
		Log.error("Could not save %d unsent marker(s); they are lost." % markers.size())


## Read and clear the parked file, queueing its markers to send on the next tick.
func _claim_parked() -> void:
	_parked_frame = -1
	var stored: Variant = _context.storage.read_json(_file_name())
	if stored == null:
		return
	_context.storage.delete(_file_name())
	var markers := _valid_markers(stored)
	if markers.is_empty():
		return
	var size: int = _context.settings.marker_batch_size
	for start in range(0, markers.size(), size):
		_retries.append({"markers": markers.slice(start, start + size), "attempt": 1, "wait": 0.0})
	_enforce_cap()
	Log.info("Restored %d saved marker(s)." % markers.size())


static func _valid_markers(stored: Variant) -> Array:
	if not (stored is Array):
		return []
	return stored.filter(func(m): return m is Dictionary and m.has("eventName"))


func _send_batch(markers: Array, attempt: int) -> void:
	var batch_id := _next_batch_id
	_next_batch_id += 1
	_in_flight[batch_id] = markers
	var response: HttpResponse = await _context.api.post_markers(markers)
	_in_flight.erase(batch_id)
	if response.is_success():
		Log.info("Sent %d marker(s)." % markers.size())
		_log_rejections(response, markers.size())
		return
	if _is_permanent_rejection(response):
		Log.error(
			(
				"Dropped %d marker(s): %s %s"
				% [markers.size(), response.describe(), response.text().left(200)]
			)
		)
		return
	if attempt >= Constants.MARKER_MAX_SEND_ATTEMPTS or _stopped:
		Log.error(
			(
				"Dropped %d marker(s) after %d attempt(s): %s"
				% [markers.size(), attempt, response.describe()]
			)
		)
		return
	var backoff := Constants.MARKER_RETRY_BASE_DELAY_SEC * pow(2.0, attempt - 1)
	var delay := maxf(backoff, response.retry_after_sec())
	_retries.append({"markers": markers, "attempt": attempt + 1, "wait": delay})
	Log.warn(
		(
			"Failed to send %d marker(s) (%s); retrying in %ds (attempt %d of %d)."
			% [
				markers.size(),
				response.describe(),
				int(delay),
				attempt,
				Constants.MARKER_MAX_SEND_ATTEMPTS
			]
		)
	)
	_enforce_cap()


## A 200 can still carry per-marker rejections (invalid shape, subscription limits).
static func _log_rejections(response: HttpResponse, sent: int) -> void:
	var parsed: Variant = JsonCodec.parse(response.text())
	if not (parsed is Dictionary) or int(parsed.get("rejectedMarkersCount", 0)) <= 0:
		return
	var reasons := PackedStringArray()
	for rejected in parsed.get("rejectedMarkers", []).slice(0, 5):
		if rejected is Dictionary:
			reasons.append(str(rejected.get("reason", "unknown")))
	Log.warn(
		(
			"%d of %d marker(s) were rejected: %s"
			% [int(parsed["rejectedMarkersCount"]), sent, "; ".join(reasons)]
		)
	)


static func _is_permanent_rejection(response: HttpResponse) -> bool:
	if response.transport_error != "":
		return false
	# 408 (timeout) and 429 (rate limited) are worth retrying; other 4xx are not.
	return (
		response.status >= 400
		and response.status < 500
		and response.status != 408
		and response.status != 429
	)


func _tick_retries(delta: float) -> void:
	if _retries.is_empty():
		return
	var due: Array = []
	for entry in _retries:
		entry["wait"] -= delta
		if entry["wait"] <= 0.0:
			due.append(entry)
	for entry in due:
		_retries.erase(entry)
		_send_batch(entry["markers"], entry["attempt"])


func _flush_retries_now() -> void:
	var entries := _retries.duplicate()
	_retries.clear()
	for entry in entries:
		_send_batch(entry["markers"], entry["attempt"])


func _unsent_count() -> int:
	var count := _pending.size()
	for entry in _retries:
		count += entry["markers"].size()
	return count


func _in_flight_count() -> int:
	var count := 0
	for id in _in_flight:
		count += _in_flight[id].size()
	return count


## Bound memory during long outages: drop the oldest unsent markers first.
func _enforce_cap() -> void:
	var over := _unsent_count() - Constants.MARKER_MAX_BUFFERED
	if over <= 0:
		return
	var dropped := 0
	while over > 0 and not _retries.is_empty():
		var oldest: Array = _retries[0]["markers"]
		over -= oldest.size()
		dropped += oldest.size()
		_retries.remove_at(0)
	if over > 0:
		dropped += over
		_pending = _pending.slice(over)
	Log.error("Marker buffer full; dropped %d oldest marker(s)." % dropped)
