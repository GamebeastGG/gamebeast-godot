@tool
extends EditorPlugin
## Registers the Gamebeast autoload, the Project Settings under `gamebeast/`, and the heatmap
## dock. Disabling the plugin removes the autoload and dock; configured settings are kept.

const AUTOLOAD_NAME := "Gamebeast"
const AUTOLOAD_PATH := "res://addons/gamebeast/gamebeast.gd"
const Settings := preload("internal/settings.gd")
const HeatmapDock := preload("editor/heatmap_dock.gd")

var _dock: Control


func _enter_tree() -> void:
	Settings.register()
	_dock = HeatmapDock.new()
	_dock.name = "Gamebeast"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	Settings.register()
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	Settings.unregister()
	ProjectSettings.save()
