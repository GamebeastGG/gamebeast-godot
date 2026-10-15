## Deeplink and UTM attribution read from a landing URL, ported from gamebeast-js
## `packages/core/src/attribution.ts`. Used on Web exports, where the game page's URL carries the
## UTM parameters (`utm_id=gb_<slug>` marks a Gamebeast deeplink).

const Uuid := preload("uuid.gd")

const PREFIX := "gb_"
const UTM_FIELDS := ["source", "medium", "campaign", "content", "term", "id"]
const MAX_UTM_LENGTH := 512
const MAX_SLUG_LENGTH := 128


## Returns {"utm": {...}, "deeplinkData"?: {slug, interactionId}}, or {} when the URL carries no
## utm_* parameters (an ordinary visit).
static func parse(url: String) -> Dictionary:
	var query := _query_params(url)
	var utm := {}
	for field in UTM_FIELDS:
		var value: String = str(query.get("utm_" + field, "")).strip_edges()
		if value != "":
			utm[field] = value.left(MAX_UTM_LENGTH)
	if utm.is_empty():
		return {}
	var attribution := {"utm": utm}
	var id: String = utm.get("id", "")
	if id.begins_with(PREFIX):
		var slug := id.substr(PREFIX.length())
		if slug != "" and slug.length() <= MAX_SLUG_LENGTH:
			attribution["deeplinkData"] = {"slug": slug, "interactionId": Uuid.v4()}
	return attribution


## Query parameters by exact name, URL-decoded. First value wins (like URLSearchParams.get).
static func _query_params(url: String) -> Dictionary:
	var params := {}
	var start := url.find("?")
	if start < 0:
		return params
	var query := url.substr(start + 1)
	var hash_index := query.find("#")
	if hash_index >= 0:
		query = query.substr(0, hash_index)
	for pair in query.split("&", false):
		var separator: int = pair.find("=")
		var key: String = pair if separator < 0 else pair.substr(0, separator)
		var value: String = "" if separator < 0 else pair.substr(separator + 1)
		key = key.replace("+", " ").uri_decode()
		value = value.replace("+", " ").uri_decode()
		if not params.has(key):
			params[key] = value
	return params
