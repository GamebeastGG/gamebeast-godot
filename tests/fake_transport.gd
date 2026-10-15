extends RefCounted
## In-memory transport for tests. Requests are recorded; each one is answered either from the
## queued responses (immediately) or, in manual mode, when the test calls `resolve`.

const HttpResponse := preload("res://addons/gamebeast/internal/http_response.gd")
const JsonCodec := preload("res://addons/gamebeast/internal/json_codec.gd")


class Pending:
	extends RefCounted
	signal resolved(response: HttpResponse)
	var method: int
	var url: String
	var headers: Dictionary
	var body: String
	var json: Variant


## Every request made, oldest first.
var requests: Array = []
## When true, requests wait for resolve(); otherwise they take the next queued response.
var manual := false
## Responses for automatic mode, consumed in order. Falls back to `default_response`.
var queued: Array = []
var default_response: Callable = func(_p): return HttpResponse.of(200, "{}")
var _waiting: Array = []


func request(
	method: int, url: String, headers: Dictionary, body: PackedByteArray = PackedByteArray()
) -> HttpResponse:
	var pending := Pending.new()
	pending.method = method
	pending.url = url
	pending.headers = headers
	pending.body = body.get_string_from_utf8()
	pending.json = JsonCodec.parse(pending.body)
	requests.append(pending)
	if manual:
		_waiting.append(pending)
		return await pending.resolved
	if not queued.is_empty():
		var next: Variant = queued.pop_front()
		return next.call(pending) if next is Callable else next
	return default_response.call(pending)


## Answer the oldest waiting request (manual mode).
func resolve(response: HttpResponse) -> void:
	var pending: Pending = _waiting.pop_front()
	pending.resolved.emit(response)


func waiting_count() -> int:
	return _waiting.size()


func requests_to(path: String) -> Array:
	return requests.filter(func(r): return r.url.contains(path))


static func json(code: int, value: Variant, headers: Dictionary = {}) -> HttpResponse:
	return HttpResponse.of(code, JSON.stringify(value), headers)
