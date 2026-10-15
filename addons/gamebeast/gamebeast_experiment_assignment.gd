class_name GamebeastExperimentAssignment
extends RefCounted
## An active experiment assignment for the local player. Assignments are resolved by the backend
## whenever a configuration is evaluated; the values you read through [code]Gamebeast.configs[/code]
## already include the assigned group's changes.

var experiment_id: int = 0
## Display name of the experiment. Empty until the experiment catalog has loaded.
var experiment_name: String = ""
var group_id: int = 0
## Display label of the assigned group. Empty until the experiment catalog has loaded.
var group_label: String = ""
## Alias of the configuration the experiment applies to.
var configuration_alias: String = ""
## "weightedHash", "roundRobin" or "manual".
var source: String = ""


func to_dictionary() -> Dictionary:
	return {
		"experiment_id": experiment_id,
		"experiment_name": experiment_name,
		"group_id": group_id,
		"group_label": group_label,
		"configuration_alias": configuration_alias,
		"source": source,
	}


func _to_string() -> String:
	return (
		"<Experiment %d '%s' group %d '%s' (%s)>"
		% [experiment_id, experiment_name, group_id, group_label, configuration_alias]
	)
