class_name GamebeastSubscription
extends RefCounted
## A config subscription returned by [method GamebeastConfigs.on_changed],
## [method GamebeastConfigs.observe] and [method GamebeastConfigs.on_ready]. Call [method cancel]
## to stop receiving callbacks. Subscriptions to a method of an object that has since been freed
## (e.g. [code]on_changed("Game.Speed", _on_speed_changed)[/code] from a node) are dropped
## automatically, so a node doesn't need to cancel in [code]_exit_tree[/code]. Lambdas don't
## track their captures: cancel those yourself when the node leaves the tree.

var callback: Callable
var _cancelled := false


func _init(target: Callable) -> void:
	callback = target


func cancel() -> void:
	_cancelled = true


func is_active() -> bool:
	return not _cancelled and callback.is_valid()
