## One HTTP response as the SDK sees it. `transport_error` is non-empty when no HTTP response
## arrived at all (DNS, TLS, timeout, offline), in which case `status` is 0.

var status: int = 0
var body: PackedByteArray = PackedByteArray()
## Lowercased header name -> value.
var headers: Dictionary = {}
var transport_error: String = ""


static func of(code: int, text: String = "", response_headers: Dictionary = {}) -> RefCounted:
	var response := new()
	response.status = code
	response.body = text.to_utf8_buffer()
	response.headers = response_headers
	return response


static func failed(reason: String) -> RefCounted:
	var response := new()
	response.transport_error = reason
	return response


func is_success() -> bool:
	return transport_error == "" and status >= 200 and status < 300


func is_not_modified() -> bool:
	return transport_error == "" and status == 304


func text() -> String:
	return body.get_string_from_utf8()


## `retry-after` in seconds, or 0 when absent or not a number of seconds.
func retry_after_sec() -> float:
	var value: String = str(headers.get("retry-after", "")).strip_edges()
	return float(value) if value.is_valid_float() else 0.0


func describe() -> String:
	if transport_error != "":
		return "transport error: " + transport_error
	return "HTTP %d" % status
