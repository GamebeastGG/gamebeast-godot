## Targeting context sent with configuration evaluations: standard device/app properties,
## overlaid with the developer's user_properties (developer values win per key).

const Constants := preload("constants.gd")
const Log := preload("log.gd")

static var _device: Dictionary = {}


static func device_properties() -> Dictionary:
	if _device.is_empty():
		_device = {
			"platform": OS.get_name().to_lower(),
			"operatingSystem": (OS.get_name() + " " + OS.get_version()).strip_edges(),
			"deviceModel": OS.get_model_name(),
			"deviceType": device_type(),
			"systemLanguage": OS.get_locale_language(),
			"appVersion": str(ProjectSettings.get_setting("application/config/version", "")),
		}
	return _device


static func device_type() -> String:
	if OS.has_feature("web"):
		return "web"
	if OS.has_feature("mobile"):
		return "mobile"
	if OS.has_feature("pc"):
		return "desktop"
	return "unknown"


static func build(user_properties: Dictionary) -> Dictionary:
	var properties := device_properties().duplicate()
	for key in user_properties:
		var name := str(key).strip_edges()
		if name == "":
			continue
		var value: Variant = _context_value(user_properties[key])
		if value == null and user_properties[key] != null:
			Log.warn(
				"user_properties['%s'] is not a string, number, bool or array; skipped." % name
			)
			continue
		properties[name] = value
	if properties.size() > Constants.CONTEXT_MAX_PROPERTIES:
		Log.warn(
			(
				"More than %d context properties; extra ones may be rejected."
				% Constants.CONTEXT_MAX_PROPERTIES
			)
		)
	return properties


static func _context_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_STRING, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return null if is_nan(value) or is_inf(value) else value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return _scalar_array(value)
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return _scalar_array(value)
		_:
			return null


static func _scalar_array(value: Variant) -> Array:
	var out := []
	for item in value:
		if typeof(item) in [TYPE_STRING, TYPE_BOOL, TYPE_INT, TYPE_FLOAT]:
			out.append(item)
	return out
