@tool
extends RefCounted
## Renders the top-down image a heatmap is drawn over.
##
## Heatmaps are laid out on the XZ plane (the backend buckets `position` by x and z). 3D scenes
## are rendered with an orthographic camera looking straight down -Y. 2D scenes map (x, y) to
## (x, z), matching [method GamebeastMarkers.send_position]. The image is flipped so its top row
## is the region's maximum Z, the same orientation the Unity SDK uploads.

## Largest image side. Bigger regions use more world units per pixel.
const MAX_PIXELS := 2048
## The backend accepts resolution factors (world units per pixel) from 1 to 255.
const MIN_RESOLUTION := 1.0
const MAX_RESOLUTION := 255.0
## Render layers 1-20 only: the editor draws gizmos and the grid on higher layers.
const CULL_MASK := 0xFFFFF


## Region math shared by both renderers: {min_x, max_x, min_z, max_z, size_px, resolution}.
static func plan(corner_a: Vector3, corner_b: Vector3) -> Dictionary:
	var min_x := minf(corner_a.x, corner_b.x)
	var max_x := maxf(corner_a.x, corner_b.x)
	var min_z := minf(corner_a.z, corner_b.z)
	var max_z := maxf(corner_a.z, corner_b.z)
	var extent := maxf(max_x - min_x, max_z - min_z)
	var resolution := clampf(ceilf(extent / MAX_PIXELS), MIN_RESOLUTION, MAX_RESOLUTION)
	var size := Vector2i(
		maxi(1, ceili((max_x - min_x) / resolution)), maxi(1, ceili((max_z - min_z) / resolution))
	)
	return {
		"min_x": min_x,
		"max_x": max_x,
		"min_z": min_z,
		"max_z": max_z,
		"size_px": size,
		"resolution": resolution,
	}


## Coroutine. Returns {ok, image: Image, resolution, error}.
static func render_3d(
	host: Node, world: World3D, corner_a: Vector3, corner_b: Vector3
) -> Dictionary:
	var region := plan(corner_a, corner_b)
	var viewport := _viewport(region["size_px"])
	viewport.world_3d = world
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = region["max_z"] - region["min_z"]
	camera.cull_mask = CULL_MASK
	var top := maxf(corner_a.y, corner_b.y) + 50.0
	var bottom := minf(corner_a.y, corner_b.y) - 50.0
	camera.position = Vector3(
		(region["min_x"] + region["max_x"]) * 0.5, top, (region["min_z"] + region["max_z"]) * 0.5
	)
	# Looking down -Y: screen right is +X, screen up is -Z.
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	camera.near = 0.05
	camera.far = maxf(1.0, top - bottom)
	viewport.add_child(camera)
	camera.current = true
	return await _capture(host, viewport, region)


## Coroutine. Corners are 2D positions mapped to (x, 0, y). Returns {ok, image, resolution, error}.
static func render_2d(
	host: Node, world: World2D, corner_a: Vector3, corner_b: Vector3
) -> Dictionary:
	var region := plan(corner_a, corner_b)
	var viewport := _viewport(region["size_px"])
	viewport.world_2d = world
	var camera := Camera2D.new()
	camera.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	camera.position = Vector2(
		(region["min_x"] + region["max_x"]) * 0.5, (region["min_z"] + region["max_z"]) * 0.5
	)
	camera.zoom = Vector2.ONE / region["resolution"]
	viewport.add_child(camera)
	camera.make_current()
	return await _capture(host, viewport, region)


static func _viewport(size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.own_world_3d = false
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	return viewport


static func _capture(host: Node, viewport: SubViewport, region: Dictionary) -> Dictionary:
	host.add_child(viewport)
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	if image == null or image.is_empty():
		return {"ok": false, "error": "the renderer returned no image (is rendering disabled?)"}
	# Top row = maximum Z, matching the orientation heatmaps are drawn in.
	image.flip_y()
	return {"ok": true, "image": image, "resolution": region["resolution"]}
