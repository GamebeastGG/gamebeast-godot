## Typed access to the Gamebeast SDK HTTP API. Owns the base URL and the per-route headers:
## - every route: `authorization`, `sdkversion`
## - v2 routes: `environment`
## - v1 routes: `isstudio`, `serverid` (the session id), `universeid: 0`

enum FetchStatus { UPDATED, NOT_MODIFIED, NOT_FOUND, FAILED }

const Constants := preload("constants.gd")
const GbEnvironment := preload("environment.gd")
const HttpResponse := preload("http_response.gd")
const JsonCodec := preload("json_codec.gd")

var session_id: String

var _transport: Variant
var _base_url: String
var _api_key: String
var _environment_alias: String


func _init(transport: Variant, api_key: String, environment_alias: String, api_url: String) -> void:
	_transport = transport
	_api_key = api_key
	_environment_alias = environment_alias
	var url := api_url.strip_edges()
	_base_url = (url if url != "" else Constants.DEFAULT_API_URL).trim_suffix("/")


func base_url() -> String:
	return _base_url


## POST /sdk/v1/markers. Coroutine.
func post_markers(markers: Array) -> HttpResponse:
	var request := markers_request(markers)
	return await _transport.request(
		HTTPClient.METHOD_POST, request["url"], request["headers"], request["body"].to_utf8_buffer()
	)


## The marker request pieces, also used by the Web keepalive flush.
func markers_request(markers: Array) -> Dictionary:
	return {
		"url": _base_url + "/sdk/v1/markers",
		"headers": v1_headers(),
		"body": JsonCodec.stringify({"markers": markers}),
	}


## POST /sdk/v2/configurations/evaluate. Coroutine. Returns {status, response, error}.
func evaluate_configuration(
	alias: String, known_hash: String, distinct_id: String, properties: Dictionary
) -> Dictionary:
	var body := {
		"configuration": alias,
		"unit": {"type": "user", "distinctId": distinct_id},
	}
	if not properties.is_empty():
		body["context"] = {
			"schemaVersion": Constants.EVALUATION_CONTEXT_SCHEMA_VERSION,
			"properties": properties,
		}
	if known_hash != "":
		body["knownHash"] = known_hash
	var response: HttpResponse = await _transport.request(
		HTTPClient.METHOD_POST,
		_base_url + "/sdk/v2/configurations/evaluate",
		v2_headers(),
		JsonCodec.stringify(body).to_utf8_buffer()
	)
	if response.transport_error != "":
		return _result(FetchStatus.FAILED, null, response.describe())
	if response.is_not_modified():
		return _result(FetchStatus.NOT_MODIFIED)
	var parsed: Variant = JsonCodec.parse(response.text())
	if (
		response.status == 404
		or (
			response.status == 400
			and parsed is Dictionary
			and parsed.get("errorCode") == "CONFIGURATION_NOT_FOUND"
		)
	):
		return _result(FetchStatus.NOT_FOUND, null, _describe_error(response, parsed))
	if not response.is_success():
		return _result(FetchStatus.FAILED, null, _describe_error(response, parsed))
	if not (parsed is Dictionary) or not (parsed.get("hash") is String) or parsed["hash"] == "":
		return _result(FetchStatus.FAILED, null, "could not parse configuration response")
	# Some servers answer a matching hash with a 200 echoing it rather than a 304.
	if known_hash != "" and parsed["hash"] == known_hash:
		return _result(FetchStatus.NOT_MODIFIED)
	return _result(FetchStatus.UPDATED, parsed)


## GET /sdk/v2/status: the environment's snapshot without configuration documents. Coroutine.
## Returns {status, response, error, retry_after}. `server-id` gives this player its own rate-limit
## bucket; without it, every player behind one IP would share one.
func get_status(known_hash: String) -> Dictionary:
	var headers := v2_headers()
	headers["server-id"] = session_id.left(Constants.MARKER_SERVER_ID_MAX_LENGTH)
	if known_hash != "":
		headers["if-none-match"] = '"%s"' % known_hash
	var response: HttpResponse = await _transport.request(
		HTTPClient.METHOD_GET, _base_url + "/sdk/v2/status", headers
	)
	var result: Dictionary
	if response.transport_error != "":
		result = _result(FetchStatus.FAILED, null, response.describe())
	elif response.is_not_modified():
		result = _result(FetchStatus.NOT_MODIFIED)
	else:
		var parsed: Variant = JsonCodec.parse(response.text())
		if not response.is_success():
			result = _result(FetchStatus.FAILED, null, _describe_error(response, parsed))
		elif (
			not (parsed is Dictionary)
			or not (parsed.get("hash") is String)
			or not (parsed.get("configurations") is Array)
			or not (parsed.get("experiments") is Dictionary)
		):
			result = _result(FetchStatus.FAILED, null, "could not parse status response")
		elif known_hash != "" and parsed["hash"] == known_hash:
			result = _result(FetchStatus.NOT_MODIFIED)
		else:
			result = _result(FetchStatus.UPDATED, parsed)
	result["retry_after"] = response.retry_after_sec()
	return result


## GET /sdk/v2/experiments/active?unit-type=user. Coroutine. Returns {status, response, error}.
func get_active_experiments(known_hash: String) -> Dictionary:
	var url := _base_url + "/sdk/v2/experiments/active?unit-type=user"
	if known_hash != "":
		url += "&hash=" + known_hash.uri_encode()
	var response: HttpResponse = await _transport.request(HTTPClient.METHOD_GET, url, v2_headers())
	if response.transport_error != "":
		return _result(FetchStatus.FAILED, null, response.describe())
	if response.is_not_modified():
		return _result(FetchStatus.NOT_MODIFIED)
	var parsed: Variant = JsonCodec.parse(response.text())
	if not response.is_success():
		return _result(FetchStatus.FAILED, null, _describe_error(response, parsed))
	if not (parsed is Dictionary) or not (parsed.get("experiments") is Array):
		return _result(FetchStatus.FAILED, null, "could not parse experiments response")
	return _result(FetchStatus.UPDATED, parsed)


## POST /sdk/v1/cohorts/membership. Coroutine. Returns {ok, is_member, cohort_exists, error}.
func get_cohort_membership(cohort_name: String, distinct_id: String) -> Dictionary:
	var response: HttpResponse = await _transport.request(
		HTTPClient.METHOD_POST,
		_base_url + "/sdk/v1/cohorts/membership",
		v1_headers(),
		JsonCodec.stringify({"cohortName": cohort_name, "userIds": [distinct_id]}).to_utf8_buffer()
	)
	var parsed: Variant = (
		JsonCodec.parse(response.text()) if response.transport_error == "" else null
	)
	if not response.is_success():
		return {"ok": false, "error": _describe_error(response, parsed)}
	if not (parsed is Dictionary) or not (parsed.get("users") is Array):
		return {"ok": false, "error": "could not parse cohort response"}
	var is_member := false
	for user in parsed["users"]:
		if user is Dictionary and str(user.get("userId", "")) == distinct_id:
			is_member = user.get("isMember") == true
	return {"ok": true, "is_member": is_member, "cohort_exists": parsed.get("cohortExists") == true}


func common_headers() -> Dictionary:
	return {
		"authorization": _api_key,
		"sdkversion": Constants.SDK_VERSION_HEADER,
		"content-type": "application/json",
	}


func v2_headers() -> Dictionary:
	var headers := common_headers()
	headers["environment"] = _environment_alias
	return headers


func v1_headers() -> Dictionary:
	var headers := common_headers()
	# TODO(post-release): custom environments. v1 can only address production and development.
	headers["isstudio"] = "true" if GbEnvironment.is_studio(_environment_alias) else "false"
	headers["serverid"] = session_id.left(Constants.MARKER_SERVER_ID_MAX_LENGTH)
	headers["universeid"] = "0"
	return headers


static func _result(
	status: FetchStatus, response: Variant = null, error: String = ""
) -> Dictionary:
	return {"status": status, "response": response, "error": error}


static func _describe_error(response: HttpResponse, parsed: Variant) -> String:
	if parsed is Dictionary and parsed.has("errorCode"):
		return "%s %s: %s" % [response.describe(), parsed["errorCode"], parsed.get("message", "")]
	return "%s %s" % [response.describe(), response.text().left(200)]
