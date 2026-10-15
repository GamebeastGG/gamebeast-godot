## HTTP transport backed by HTTPRequest nodes (one per request, freed on completion). On Web
## exports HTTPRequest uses the browser's fetch; /sdk/* allows any origin, so no proxy is needed.
## Tests replace this with a fake that has the same `request` coroutine.

const Constants := preload("constants.gd")
const HttpResponse := preload("http_response.gd")

var _host: Node
var _closed := false


func _init(host: Node) -> void:
	_host = host


## Coroutine. `method` is an HTTPClient.METHOD_* value; `headers` maps name -> value.
func request(
	method: int, url: String, headers: Dictionary, body: PackedByteArray = PackedByteArray()
) -> HttpResponse:
	if _closed or not is_instance_valid(_host) or not _host.is_inside_tree():
		return HttpResponse.failed("transport closed")
	var http := HTTPRequest.new()
	http.timeout = Constants.HTTP_TIMEOUT_SEC
	http.accept_gzip = true
	http.use_threads = false
	_host.add_child(http)
	var header_lines := PackedStringArray()
	for name in headers:
		header_lines.append("%s: %s" % [name, headers[name]])
	var err := http.request_raw(url, header_lines, method, body)
	if err != OK:
		http.queue_free()
		return HttpResponse.failed("request error %d" % err)
	var result: Array = await http.request_completed
	http.queue_free()
	return _to_response(result)


func close() -> void:
	_closed = true


static func _to_response(result: Array) -> HttpResponse:
	var outcome: int = result[0]
	if outcome != HTTPRequest.RESULT_SUCCESS:
		return HttpResponse.failed(_describe_result(outcome))
	var response := HttpResponse.new()
	response.status = result[1]
	for line in result[2]:
		var separator: int = line.find(":")
		if separator > 0:
			var name: String = line.substr(0, separator).strip_edges().to_lower()
			response.headers[name] = line.substr(separator + 1).strip_edges()
	response.body = result[3]
	return response


static func _describe_result(outcome: int) -> String:
	match outcome:
		HTTPRequest.RESULT_CANT_CONNECT:
			return "can't connect"
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "can't resolve host"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake error"
		HTTPRequest.RESULT_TIMEOUT:
			return "timeout"
		HTTPRequest.RESULT_NO_RESPONSE:
			return "no response"
		_:
			return "request failed (result %d)" % outcome
