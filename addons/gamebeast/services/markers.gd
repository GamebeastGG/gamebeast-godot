class_name GamebeastMarkers
extends RefCounted
## Sends engagement markers (analytics events) to Gamebeast. Access through
## [code]Gamebeast.markers[/code].
##
## Markers are batched and flushed automatically: when a batch of 10 fills up, every 10 seconds,
## and when the game quits or goes to the background. Failed sends retry with exponential backoff
## (honouring [code]retry-after[/code]); permanent rejections (4xx) are dropped. Anything still
## unsent when the game quits or is backgrounded is persisted under user:// and delivered on the
## next launch. The backend dedupes markers by id, so a replay never double-counts.

const Constants := preload("../internal/constants.gd")
const Context := preload("../internal/context.gd")
const HttpResponse := preload("../internal/http_response.gd")
const JsonCodec := preload("../internal/json_codec.gd")
const Log := preload("../internal/log.gd")
const Storage := preload("../internal/storage.gd")
const Uuid := preload("../internal/uuid.gd")

var _context: Context
var _pending: Array = []
## Failed batches awaiting resend: {"markers": Array, "attempt": int, "wait": float}
var _retries: Array = []
## Batches currently being sent, by batch id. Included in persisted snapshots.
var _in_flight: Dictionary = {}
var _next_batch_id := 0
var _since_flush := 0.0
var _stopped := false


func _init(context: Context) -> void:
	_context = context
	_restore_persisted()


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
	if _pending.size() >= Constants.MARKER_BATCH_SIZE:
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


## Send everything waiting in the current batch now.
func flush() -> void:
	_since_flush = 0.0
	while not _pending.is_empty():
		var batch := _pending.slice(0, Constants.MARKER_BATCH_SIZE)
		_pending = _pending.slice(Constants.MARKER_BATCH_SIZE)
		_send_batch(batch, 1)


## Number of markers not yet confirmed by the backend (pending, retrying or in flight).
func buffered_count() -> int:
	var count := _pending.size()
	for entry in _retries:
		count += entry["markers"].size()
	for id in _in_flight:
		count += _in_flight[id].size()
	return count


# --- Internal (called by the Gamebeast autoload) -----------------------------------------------


func _tick(delta: float) -> void:
	if _stopped:
		return
	_tick_retries(delta)
	if _pending.is_empty():
		_since_flush = 0.0
		return
	_since_flush += delta
	if _since_flush >= Constants.MARKER_FLUSH_INTERVAL_SEC:
		flush()


## Write every unconfirmed marker to disk (quit, backgrounding, page hide).
func _persist() -> void:
	var snapshot := _snapshot()
	if snapshot.is_empty():
		_context.storage.delete(_file_name())
	else:
		_context.storage.write_json(_file_name(), snapshot)


## Persist, then send everything now, skipping retry backoff.
func _persist_and_flush() -> void:
	_persist()
	_flush_retries_now()
	flush()


## Web page hide: persist, then hand everything to keepalive fetches, which outlive the page.
## The markers stay persisted, so if a keepalive request fails they replay on the next visit.
func _persist_and_flush_keepalive(post: Callable) -> void:
	_persist()
	var batches: Array = []
	for entry in _retries:
		batches.append(entry["markers"])
	_retries.clear()
	while not _pending.is_empty():
		batches.append(_pending.slice(0, Constants.MARKER_BATCH_SIZE))
		_pending = _pending.slice(Constants.MARKER_BATCH_SIZE)
	for batch in batches:
		var request: Dictionary = _context.api.markers_request(batch)
		post.call(request["url"], request["headers"], request["body"])


func _shutdown() -> void:
	_persist_and_flush()
	_stopped = true


func _file_name() -> String:
	return "markers_%s.json" % Storage.safe_name(_context.environment_alias)


func _snapshot() -> Array:
	var snapshot: Array = []
	for id in _in_flight:
		snapshot.append_array(_in_flight[id])
	for entry in _retries:
		snapshot.append_array(entry["markers"])
	snapshot.append_array(_pending)
	return snapshot


func _restore_persisted() -> void:
	var stored: Variant = _context.storage.read_json(_file_name())
	_context.storage.delete(_file_name())
	if not (stored is Array) or stored.is_empty():
		return
	var markers: Array = stored.filter(func(m): return m is Dictionary and m.has("eventName"))
	if markers.size() > Constants.MARKER_MAX_BUFFERED:
		Log.warn(
			(
				"Dropping %d persisted marker(s) over the buffer cap."
				% (markers.size() - Constants.MARKER_MAX_BUFFERED)
			)
		)
		markers = markers.slice(markers.size() - Constants.MARKER_MAX_BUFFERED)
	for start in range(0, markers.size(), Constants.MARKER_BATCH_SIZE):
		_retries.append(
			{
				"markers": markers.slice(start, start + Constants.MARKER_BATCH_SIZE),
				"attempt": 1,
				"wait": 0.0
			}
		)
	Log.info("Restored %d persisted marker(s) from a previous session." % markers.size())


func _send_batch(markers: Array, attempt: int) -> void:
	var batch_id := _next_batch_id
	_next_batch_id += 1
	_in_flight[batch_id] = markers
	var response: HttpResponse = await _context.api.post_markers(markers)
	_in_flight.erase(batch_id)
	if response.is_success():
		Log.info("Sent %d marker(s)." % markers.size())
		if buffered_count() == 0:
			_context.storage.delete(_file_name())
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


## Bound memory during long outages: drop the oldest buffered markers first.
func _enforce_cap() -> void:
	var over := buffered_count() - Constants.MARKER_MAX_BUFFERED
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
