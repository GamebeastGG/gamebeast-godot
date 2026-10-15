@tool
extends VBoxContainer
## The Gamebeast editor dock: manage heatmaps and upload the overhead image they are drawn over.
## Pick two corner nodes in the open scene (Node3D or Node2D), render, and upload. The key is
## stored in this project's editor metadata (.godot/), not in project.godot.

const HeatmapApi := preload("heatmap_api.gd")
const HttpTransport := preload("../internal/http_transport.gd")
const OverheadRenderer := preload("overhead_renderer.gd")
const Settings := preload("../internal/settings.gd")

const META_SECTION := "gamebeast"

var _key_edit: LineEdit
var _url_edit: LineEdit
var _heatmap_picker: OptionButton
var _name_edit: LineEdit
var _description_edit: LineEdit
var _corner_labels: Array[Label] = []
var _preview: TextureRect
var _status: Label
var _details_box: VBoxContainer
var _busy_buttons: Array[Button] = []

var _heatmaps: Array = []
var _corners: Array = [null, null]
var _corners_2d := false
var _rendered: Image
var _rendered_resolution := 1.0


func _ready() -> void:
	if get_child_count() > 0:
		return
	custom_minimum_size = Vector2(220, 0)
	_build_connection_section()
	_build_heatmap_section()
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_load_key()
	_refresh_details()


# --- UI construction -----------------------------------------------------------------------------


func _build_connection_section() -> void:
	add_child(_header("Gamebeast heatmaps"))
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "API key (needs heatmaps permissions)"
	_key_edit.secret = true
	_key_edit.text_changed.connect(func(_t): _save_key())
	add_child(_key_edit)
	_url_edit = LineEdit.new()
	_url_edit.placeholder_text = "API URL (optional)"
	_url_edit.text_changed.connect(func(_t): _save_key())
	add_child(_url_edit)
	add_child(_button("Fetch heatmaps", _fetch))
	var row := HBoxContainer.new()
	_heatmap_picker = OptionButton.new()
	_heatmap_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_heatmap_picker.item_selected.connect(func(_i): _refresh_details())
	row.add_child(_heatmap_picker)
	row.add_child(_button("New", _create))
	add_child(row)


func _build_heatmap_section() -> void:
	_details_box = VBoxContainer.new()
	add_child(_details_box)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Name"
	_details_box.add_child(_name_edit)
	_description_edit = LineEdit.new()
	_description_edit.placeholder_text = "Description"
	_details_box.add_child(_description_edit)
	var detail_row := HBoxContainer.new()
	detail_row.add_child(_button("Save details", _save_details))
	detail_row.add_child(_button("Delete", _delete))
	_details_box.add_child(detail_row)

	_details_box.add_child(_header("Region"))
	for i in range(2):
		var corner_row := HBoxContainer.new()
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		_corner_labels.append(label)
		corner_row.add_child(label)
		corner_row.add_child(_button("Use selected", _use_selected.bind(i)))
		_details_box.add_child(corner_row)
	var render_row := HBoxContainer.new()
	render_row.add_child(_button("Render preview", _render))
	render_row.add_child(_button("Upload", _upload))
	_details_box.add_child(render_row)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(0, 200)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_details_box.add_child(_preview)


func _header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	return label


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	_busy_buttons.append(button)
	return button


# --- Actions -------------------------------------------------------------------------------------


func _fetch() -> void:
	var result: Dictionary = await _run("Fetching heatmaps...", func(api): return await api.list())
	if not result.get("ok", false):
		return
	_heatmaps = result["heatmaps"]
	_heatmap_picker.clear()
	for heatmap in _heatmaps:
		_heatmap_picker.add_item(str(heatmap.get("name", heatmap.get("id", "?"))))
	_set_status("%d heatmap(s)." % _heatmaps.size())
	_refresh_details()


func _create() -> void:
	var details := {
		"name": "New heatmap",
		"description": "",
		"bounds": _bounds() if _corners_ready() else _default_bounds(),
		"resolutionFactor": 1.0,
	}
	var result: Dictionary = await _run(
		"Creating heatmap...", func(api): return await api.create(details)
	)
	if result.get("ok", false):
		await _fetch()
		_select_by_id(result["id"])
		_set_status("Created heatmap. Name it, pick corners, then render and upload.")


func _save_details() -> void:
	var heatmap := _selected()
	if heatmap.is_empty():
		return
	var details := _details_from(heatmap)
	details["name"] = _name_edit.text.strip_edges()
	details["description"] = _description_edit.text.strip_edges()
	var id := str(heatmap["id"])
	var result: Dictionary = await _run(
		"Saving...", func(api): return await api.update(id, details)
	)
	if result.get("ok", false):
		heatmap["name"] = details["name"]
		heatmap["description"] = details["description"]
		_heatmap_picker.set_item_text(_heatmap_picker.selected, details["name"])
		_set_status("Saved.")


func _delete() -> void:
	var heatmap := _selected()
	if heatmap.is_empty():
		return
	var id := str(heatmap["id"])
	var result: Dictionary = await _run("Deleting...", func(api): return await api.delete(id))
	if result.get("ok", false):
		await _fetch()
		_set_status("Deleted.")


func _use_selected(index: int) -> void:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	if nodes.is_empty():
		_set_status("Select a Node3D or Node2D in the scene first.")
		return
	var node: Node = nodes[0]
	if node is Node3D:
		_corners[index] = (node as Node3D).global_position
		_corners_2d = false
	elif node is Node2D:
		var p := (node as Node2D).global_position
		_corners[index] = Vector3(p.x, 0.0, p.y)
		_corners_2d = true
	else:
		_set_status("'%s' is not a Node3D or Node2D." % node.name)
		return
	_rendered = null
	_preview.texture = null
	_refresh_corner_labels()


func _render() -> void:
	if not _corners_ready():
		_set_status("Pick both corners first.")
		return
	_set_busy(true, "Rendering...")
	var result: Dictionary
	if _corners_2d:
		var world_2d := EditorInterface.get_editor_viewport_2d().world_2d
		result = await OverheadRenderer.render_2d(self, world_2d, _corners[0], _corners[1])
	else:
		var world_3d := EditorInterface.get_editor_viewport_3d(0).find_world_3d()
		result = await OverheadRenderer.render_3d(self, world_3d, _corners[0], _corners[1])
	_set_busy(false)
	if not result.get("ok", false):
		_set_status("Render failed: " + str(result.get("error", "")))
		return
	_rendered = result["image"]
	_rendered_resolution = result["resolution"]
	_preview.texture = ImageTexture.create_from_image(_rendered)
	_set_status(
		(
			"Rendered %dx%d at %s world units per pixel."
			% [_rendered.get_width(), _rendered.get_height(), _rendered_resolution]
		)
	)


func _upload() -> void:
	var heatmap := _selected()
	if heatmap.is_empty() or _rendered == null:
		_set_status("Select a heatmap and render a preview first.")
		return
	var id := str(heatmap["id"])
	var details := _details_from(heatmap)
	details["bounds"] = _bounds()
	details["resolutionFactor"] = _rendered_resolution
	var png := _rendered.save_png_to_buffer()
	var result: Dictionary = await _run(
		"Uploading...",
		func(api):
			var updated: Dictionary = await api.update(id, details)
			if not updated.get("ok", false):
				return updated
			return await api.upload_image(id, png)
	)
	if result.get("ok", false):
		heatmap["bounds"] = details["bounds"]
		heatmap["resolutionFactor"] = details["resolutionFactor"]
		_set_status("Uploaded the region and image.")


# --- Helpers -------------------------------------------------------------------------------------


## Runs `action(api)` with buttons disabled. Shows errors in the status line.
func _run(message: String, action: Callable) -> Dictionary:
	var key := _key_edit.text.strip_edges()
	if key == "":
		_set_status("Enter an API key first.")
		return {"ok": false}
	_set_busy(true, message)
	var api := HeatmapApi.new(HttpTransport.new(self), key, _url_edit.text)
	var result: Dictionary = await action.call(api)
	_set_busy(false)
	if not result.get("ok", false):
		_set_status("Failed: " + str(result.get("error", "")))
	return result


func _selected() -> Dictionary:
	var index := _heatmap_picker.selected
	return _heatmaps[index] if index >= 0 and index < _heatmaps.size() else {}


func _select_by_id(id: String) -> void:
	for i in range(_heatmaps.size()):
		if str(_heatmaps[i].get("id")) == id:
			_heatmap_picker.select(i)
	_refresh_details()


static func _details_from(heatmap: Dictionary) -> Dictionary:
	return {
		"name": str(heatmap.get("name", "")),
		"description": str(heatmap.get("description", "")),
		"bounds": heatmap.get("bounds", _default_bounds()),
		"resolutionFactor": clampf(float(heatmap.get("resolutionFactor", 1.0)), 1.0, 255.0),
	}


func _corners_ready() -> bool:
	return _corners[0] != null and _corners[1] != null


func _bounds() -> Dictionary:
	return {"pointA": _point(_corners[0]), "pointB": _point(_corners[1])}


static func _default_bounds() -> Dictionary:
	return {"pointA": {"x": 0, "y": 0, "z": 0}, "pointB": {"x": 100, "y": 0, "z": 100}}


static func _point(v: Vector3) -> Dictionary:
	return {"x": v.x, "y": v.y, "z": v.z}


func _refresh_details() -> void:
	var heatmap := _selected()
	_details_box.visible = not heatmap.is_empty()
	if heatmap.is_empty():
		return
	_name_edit.text = str(heatmap.get("name", ""))
	_description_edit.text = str(heatmap.get("description", ""))
	_refresh_corner_labels()


func _refresh_corner_labels() -> void:
	for i in range(2):
		var corner: Variant = _corners[i]
		_corner_labels[i].text = (
			"Corner %s: %s" % ["AB"[i], "(none)" if corner == null else str(corner)]
		)


func _set_busy(busy: bool, message: String = "") -> void:
	for button in _busy_buttons:
		button.disabled = busy
	if message != "":
		_set_status(message)


func _set_status(text: String) -> void:
	_status.text = text


func _load_key() -> void:
	var settings := EditorInterface.get_editor_settings()
	var key: String = settings.get_project_metadata(META_SECTION, "heatmap_api_key", "")
	if key == "":
		key = str(ProjectSettings.get_setting(Settings.API_KEY, ""))
	_key_edit.text = key
	_url_edit.text = settings.get_project_metadata(
		META_SECTION, "heatmap_api_url", str(ProjectSettings.get_setting(Settings.API_URL, ""))
	)


func _save_key() -> void:
	var settings := EditorInterface.get_editor_settings()
	settings.set_project_metadata(META_SECTION, "heatmap_api_key", _key_edit.text.strip_edges())
	settings.set_project_metadata(META_SECTION, "heatmap_api_url", _url_edit.text.strip_edges())
