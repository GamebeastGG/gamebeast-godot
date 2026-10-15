## Converts Godot values into JSON-safe values for marker payloads and evaluation context.
## Vectors become plain arrays ([x, y, z]) to match the wire format the other SDKs use; the
## reserved `position` marker property is read by heatmaps as [x, y, z] on the XZ plane.

const Log := preload("log.gd")


## Returns [ok: bool, value]. Objects (other than null) and other non-data types fail.
static func to_json_value(value: Variant, path: String = "") -> Array:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return [true, value]
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return [false, null]
			return [true, value]
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return [true, str(value)]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [true, [value.x, value.y]]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [true, [value.x, value.y, value.z]]
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return [true, [value.x, value.y, value.z, value.w]]
		TYPE_COLOR:
			return [true, [value.r, value.g, value.b, value.a]]
		TYPE_DICTIONARY:
			return _convert_dictionary(value, path)
		TYPE_ARRAY:
			return _convert_array(value, path)
		_:
			if typeof(value) >= TYPE_PACKED_BYTE_ARRAY and typeof(value) <= TYPE_MAX:
				return _convert_array(Array(value), path)
			return [false, null]


static func _convert_dictionary(dict: Dictionary, path: String) -> Array:
	var out := {}
	for key in dict:
		var key_path := path + "." + str(key) if path != "" else str(key)
		var converted := to_json_value(dict[key], key_path)
		if not converted[0]:
			Log.warn(
				(
					"Dropped unsupported value at '%s' (%s)."
					% [key_path, type_string(typeof(dict[key]))]
				)
			)
			continue
		out[str(key)] = converted[1]
	return [true, out]


static func _convert_array(items: Array, path: String) -> Array:
	var out := []
	for i in range(items.size()):
		var converted := to_json_value(items[i], "%s[%d]" % [path, i])
		if not converted[0]:
			Log.warn("Dropped unsupported value at '%s[%d]'." % [path, i])
			continue
		out.append(converted[1])
	return [true, out]


static func stringify(value: Variant) -> String:
	return JSON.stringify(value, "", false)


## Parses JSON text. Returns null on failure (and for a literal null).
static func parse(text: String) -> Variant:
	if text.strip_edges() == "":
		return null
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data
