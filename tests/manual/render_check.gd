extends SceneTree
## Manual check of the overhead renderer with a real GPU (not headless):
## godot --path . --rendering-method gl_compatibility -s tests/manual/render_check.gd

const OverheadRenderer := preload("res://addons/gamebeast/editor/overhead_renderer.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var options := GamebeastOptions.new()
	options.configurations = ["A", "B"]
	print("configurations: ", options.configurations)
	var world := Node3D.new()
	root.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-60, 0, 0)
	world.add_child(light)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(100, 60)
	world.add_child(floor_mesh)
	# A red box near +X, -Z: should appear top-right (top row = max Z means -Z is bottom).
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.mesh.size = Vector3(10, 10, 10)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.RED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	box.material_override = material
	box.position = Vector3(40, 0, -25)
	world.add_child(box)
	var result: Dictionary = await OverheadRenderer.render_3d(
		root, world.get_world_3d(), Vector3(-50, 0, -30), Vector3(50, 5, 30)
	)
	print("render ok: ", result.get("ok"), " ", result.get("error", ""))
	if result.get("ok"):
		var image: Image = result["image"]
		print("size: ", image.get_size(), " resolution: ", result["resolution"])
		print("pixel at +X,-Z region: ", image.get_pixel(90, 55), " (row 55 of 60 = near min Z)")
		print("pixel at +X,+Z region: ", image.get_pixel(90, 5))
		image.save_png("/tmp/gb_render_check.png")
	quit()
