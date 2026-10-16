## Prefixed console logging. Info lines only print when debug logging is enabled.

static var debug_enabled := false
static var warnings_enabled := true
## Suppresses warnings and errors (test runner only).
static var silenced := false


static func info(message: String) -> void:
	if debug_enabled and not silenced:
		print("[Gamebeast] ", message)


static func warn(message: String) -> void:
	if warnings_enabled and not silenced:
		push_warning("[Gamebeast] " + message)


static func error(message: String) -> void:
	if not silenced:
		push_error("[Gamebeast] " + message)
