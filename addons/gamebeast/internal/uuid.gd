## Dashed RFC 4122 version 4 UUIDs. The marker contract validates `markerId` with `z.uuid()`,
## so ids must be dashed (the Unity SDK sends dashless ids, which the backend replaces).

const _HEX := "0123456789abcdef"

static var _crypto: Crypto


static func v4() -> String:
	if _crypto == null:
		_crypto = Crypto.new()
	var bytes := _crypto.generate_random_bytes(16)
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var out := ""
	for i in range(16):
		if i == 4 or i == 6 or i == 8 or i == 10:
			out += "-"
		out += _HEX[bytes[i] >> 4] + _HEX[bytes[i] & 0x0F]
	return out


static func is_uuid(value: String) -> bool:
	var regex := RegEx.create_from_string(
		"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
	)
	return regex.search(value.to_lower()) != null
