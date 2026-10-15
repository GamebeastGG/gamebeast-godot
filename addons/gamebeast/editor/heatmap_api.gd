@tool
extends RefCounted
## Editor-only client for the heatmap management routes (`/sdk/v1/heatmaps/*`). Uses the key
## entered in the Gamebeast dock (it needs the heatmaps:read/write permissions), not the runtime
## SDK session.

const Constants := preload("../internal/constants.gd")
const HttpResponse := preload("../internal/http_response.gd")
const HttpTransport := preload("../internal/http_transport.gd")
const JsonCodec := preload("../internal/json_codec.gd")

var _transport: Variant
var _api_key: String
var _base_url: String


func _init(transport: Variant, api_key: String, api_url: String = "") -> void:
	_transport = transport
	_api_key = api_key.strip_edges()
	var url := api_url.strip_edges()
	_base_url = (url if url != "" else Constants.DEFAULT_API_URL).trim_suffix("/")


## Coroutine. Returns {ok, heatmaps: Array[Dictionary], error}.
func list() -> Dictionary:
	var response := await _send(HTTPClient.METHOD_GET, "/sdk/v1/heatmaps/list")
	if not response.is_success():
		return {"ok": false, "error": _describe(response)}
	var parsed: Variant = JsonCodec.parse(response.text())
	if not (parsed is Array):
		return {"ok": false, "error": "could not parse heatmap list"}
	return {"ok": true, "heatmaps": parsed.filter(func(h): return h is Dictionary)}


## Coroutine. `details` = {name, description, bounds: {pointA, pointB}, resolutionFactor}.
## Returns {ok, id, error}.
func create(details: Dictionary) -> Dictionary:
	var response := await _send(HTTPClient.METHOD_POST, "/sdk/v1/heatmaps/create", details)
	if not response.is_success():
		return {"ok": false, "error": _describe(response)}
	var parsed: Variant = JsonCodec.parse(response.text())
	if not (parsed is Dictionary) or not parsed.has("id"):
		return {"ok": false, "error": "could not parse created heatmap"}
	return {"ok": true, "id": str(parsed["id"])}


## Coroutine. Returns {ok, error}.
func update(id: String, details: Dictionary) -> Dictionary:
	return _outcome(
		await _send(HTTPClient.METHOD_PUT, "/sdk/v1/heatmaps/" + id.uri_encode(), details)
	)


## Coroutine. Returns {ok, error}.
func delete(id: String) -> Dictionary:
	return _outcome(await _send(HTTPClient.METHOD_DELETE, "/sdk/v1/heatmaps/" + id.uri_encode()))


## Coroutine. Uploads the overhead image as a raw image/png body. Returns {ok, error}.
func upload_image(id: String, png: PackedByteArray) -> Dictionary:
	var headers := _headers()
	headers["content-type"] = "image/png"
	var response: HttpResponse = await _transport.request(
		HTTPClient.METHOD_POST,
		_base_url + "/sdk/v1/heatmaps/%s/image" % id.uri_encode(),
		headers,
		png
	)
	return _outcome(response)


func _send(method: int, path: String, body: Variant = null) -> HttpResponse:
	var bytes := PackedByteArray()
	if body != null:
		bytes = JsonCodec.stringify(body).to_utf8_buffer()
	return await _transport.request(method, _base_url + path, _headers(), bytes)


func _headers() -> Dictionary:
	return {
		"authorization": _api_key,
		"sdkversion": Constants.SDK_VERSION_HEADER,
		"content-type": "application/json",
		"universeid": "0",
		"serverid": "godot-editor",
		"isstudio": "true",
	}


static func _outcome(response: HttpResponse) -> Dictionary:
	return {"ok": true} if response.is_success() else {"ok": false, "error": _describe(response)}


static func _describe(response: HttpResponse) -> String:
	return "%s %s" % [response.describe(), response.text().left(300)]
