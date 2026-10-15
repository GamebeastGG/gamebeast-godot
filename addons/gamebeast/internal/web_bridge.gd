## Web-export integration through JavaScriptBridge. Godot gets no pause/close notifications when a
## browser tab is hidden or closed, so this listens for `visibilitychange` and `pagehide` (and
## `online`, to send markers saved while offline). The flush on hide goes through
## `fetch(..., {keepalive: true})`,
## which the browser completes even after the page unloads (HTTPRequest can't do that).
## Everything here is a no-op outside Web exports.

signal hidden
signal visible
## The browser came back online.
signal online

var _callbacks: Array = []
var _document: JavaScriptObject
var _window: JavaScriptObject


static func is_web() -> bool:
	return OS.has_feature("web")


func attach() -> void:
	if not is_web():
		return
	_document = JavaScriptBridge.get_interface("document")
	_window = JavaScriptBridge.get_interface("window")
	if _document == null or _window == null:
		return
	var on_visibility := JavaScriptBridge.create_callback(_on_visibility_change)
	var on_pagehide := JavaScriptBridge.create_callback(_on_pagehide)
	var on_online := JavaScriptBridge.create_callback(_on_online)
	# Keep references: callbacks are released when their JavaScriptObject is freed.
	_callbacks = [on_visibility, on_pagehide, on_online]
	_document.addEventListener("visibilitychange", on_visibility)
	_window.addEventListener("pagehide", on_pagehide)
	_window.addEventListener("online", on_online)


func detach() -> void:
	if _document != null and _callbacks.size() == 3:
		_document.removeEventListener("visibilitychange", _callbacks[0])
		_window.removeEventListener("pagehide", _callbacks[1])
		_window.removeEventListener("online", _callbacks[2])
	_callbacks = []


## The page URL, or "" outside Web.
func location_href() -> String:
	if not is_web():
		return ""
	var value: Variant = JavaScriptBridge.eval("window.location.href", true)
	return value if value is String else ""


## False only when the browser reports it is offline (true outside Web).
func is_online() -> bool:
	if not is_web():
		return true
	return JavaScriptBridge.eval("navigator.onLine !== false", true) != false


## Fire-and-forget POST that survives page unload. Browsers cap in-flight keepalive bodies at
## 64 KiB in total; the markers service keeps its hand-off under that.
func keepalive_post(url: String, headers: Dictionary, body: String) -> void:
	if not is_web():
		return
	var script := (
		(
			"try{fetch(%s,{method:'POST',keepalive:true,headers:%s,body:%s}).catch(function(){});}"
			+ "catch(e){}"
		)
		% [JSON.stringify(url), JSON.stringify(headers), JSON.stringify(body)]
	)
	JavaScriptBridge.eval(script, true)


func _on_visibility_change(_args: Array) -> void:
	if _document == null:
		return
	if str(_document.visibilityState) == "hidden":
		hidden.emit()
	else:
		visible.emit()


func _on_pagehide(_args: Array) -> void:
	hidden.emit()


func _on_online(_args: Array) -> void:
	online.emit()
