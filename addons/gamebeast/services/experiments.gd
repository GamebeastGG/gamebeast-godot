class_name GamebeastExperiments
extends RefCounted
## Read access to the experiments the local player is enrolled in. Access through
## [code]Gamebeast.experiments[/code].
##
## Enrollment is automatic: evaluating a configuration evaluates active experiments for this player
## on the backend, and the applied assignments surface here. There is nothing to opt into; this
## service exists for display, analytics segmentation and debugging. Names and group labels come
## from the status snapshots the configs service polls. With status polling off, they are fetched
## from the active experiment catalog when an unknown experiment appears.

## Emitted with the full assignment list whenever it changes (including when names resolve).
signal assignments_changed(assignments: Array[GamebeastExperimentAssignment])

const ApiClient := preload("../internal/api_client.gd")
const Context := preload("../internal/context.gd")
const Log := preload("../internal/log.gd")

## Set by the autoload: status snapshots supply the catalog, so /experiments/active isn't needed.
var catalog_from_status := false

var _context: Context
## alias -> Array of assignment metadata dictionaries from the evaluate response
var _by_config: Dictionary = {}
## experiment id -> experiment descriptor (from /status, or /experiments/active as a fallback)
var _catalog: Dictionary = {}
var _catalog_hash := ""
var _catalog_in_flight := false
var _current: Array[GamebeastExperimentAssignment] = []


func _init(context: Context) -> void:
	_context = context


## The player's active assignments across all fetched configurations, sorted by experiment id.
## Empty until the first evaluated configuration lands.
func get_assignments() -> Array[GamebeastExperimentAssignment]:
	return _current.duplicate()


## The assignment for one experiment, or null when not enrolled.
func get_assignment(experiment_id: int) -> GamebeastExperimentAssignment:
	for assignment in _current:
		if assignment.experiment_id == experiment_id:
			return assignment
	return null


# --- Internal ------------------------------------------------------------------------------------


## Called by GamebeastConfigs with the assignments echoed on an evaluated response.
func _report(alias: String, experiments: Array) -> void:
	var key := alias.to_lower()
	if _by_config.has(key) and _by_config[key]["experiments"] == experiments:
		return
	_by_config[key] = {"alias": alias, "experiments": experiments}
	_rebuild()


## Called by GamebeastConfigs with the user experiment descriptors from a changed snapshot.
func _apply_catalog(descriptors: Array) -> void:
	var catalog := {}
	for experiment in descriptors:
		if experiment is Dictionary:
			catalog[int(experiment.get("id", 0))] = experiment
	if catalog == _catalog:
		return
	_catalog = catalog
	if not _by_config.is_empty():
		_rebuild()


func _on_identity_changed() -> void:
	if _by_config.is_empty():
		return
	_by_config.clear()
	_rebuild()


func _rebuild() -> void:
	# With status polling, an experiment missing from the catalog shows up in the next snapshot,
	# which fills in its name and emits again.
	if not catalog_from_status and _has_unknown_experiment():
		await _refresh_catalog()
	var snapshot := _build_snapshot()
	if _same(snapshot, _current) and not _current.is_empty():
		return
	_current = snapshot
	assignments_changed.emit(_current.duplicate())


static func _same(
	a: Array[GamebeastExperimentAssignment], b: Array[GamebeastExperimentAssignment]
) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if (
			a[i].experiment_id != b[i].experiment_id
			or a[i].group_id != b[i].group_id
			or a[i].experiment_name != b[i].experiment_name
			or a[i].group_label != b[i].group_label
			or a[i].configuration_alias != b[i].configuration_alias
			or a[i].source != b[i].source
		):
			return false
	return true


func _has_unknown_experiment() -> bool:
	for entry in _by_config.values():
		for assignment in entry["experiments"]:
			if (
				assignment is Dictionary
				and not _catalog.has(int(assignment.get("experimentId", 0)))
			):
				return true
	return false


func _refresh_catalog() -> void:
	if _catalog_in_flight:
		return
	_catalog_in_flight = true
	var result: Dictionary = await _context.api.get_active_experiments(_catalog_hash)
	_catalog_in_flight = false
	match result["status"]:
		ApiClient.FetchStatus.UPDATED:
			var response: Dictionary = result["response"]
			_catalog_hash = str(response.get("hash", ""))
			_catalog.clear()
			for experiment in response["experiments"]:
				if experiment is Dictionary:
					_catalog[int(experiment.get("id", 0))] = experiment
			Log.info("Experiment catalog updated (%d active)." % _catalog.size())
		ApiClient.FetchStatus.NOT_MODIFIED:
			pass
		_:
			(
				Log
				. warn(
					(
						"Experiment catalog fetch failed (%s); assignments surface without names until it succeeds."
						% result["error"]
					)
				)
			)


func _build_snapshot() -> Array[GamebeastExperimentAssignment]:
	var snapshot: Array[GamebeastExperimentAssignment] = []
	for entry in _by_config.values():
		for raw in entry["experiments"]:
			if not (raw is Dictionary):
				continue
			var assignment := GamebeastExperimentAssignment.new()
			assignment.experiment_id = int(raw.get("experimentId", 0))
			assignment.group_id = int(raw.get("groupId", 0))
			assignment.source = str(raw.get("source", ""))
			assignment.configuration_alias = entry["alias"]
			var experiment: Dictionary = _catalog.get(assignment.experiment_id, {})
			assignment.experiment_name = str(experiment.get("name", ""))
			for group in experiment.get("groups", []):
				if group is Dictionary and int(group.get("id", -1)) == assignment.group_id:
					assignment.group_label = str(group.get("label", ""))
			snapshot.append(assignment)
	snapshot.sort_custom(func(a, b): return a.experiment_id < b.experiment_id)
	return snapshot
