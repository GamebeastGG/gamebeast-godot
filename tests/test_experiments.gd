extends "res://tests/test_case.gd"

const Context := preload("res://addons/gamebeast/internal/context.gd")
const ConfigTests := preload("res://tests/test_configs.gd")

var transport: FakeTransport
var storage: Storage


func before_each() -> void:
	transport = FakeTransport.new()
	storage = fresh_storage()


func _context() -> Context:
	var options := GamebeastOptions.with_api_key("key")
	options.configurations = PackedStringArray(["Game"])
	return Context.new(options, "development", transport, storage)


func _catalog() -> HttpResponse:
	return (
		FakeTransport
		. json(
			200,
			{
				"hash": "cat1",
				"requiredProperties": [],
				"experiments":
				[
					{
						"id": 7,
						"name": "Speed test",
						"unitType": "user",
						"assignmentMode": "weightedHash",
						"baseConfigurationId": 1,
						"autoAssignment": true,
						"permanentEnrollment": false,
						"requiredProperties": [],
						"startsAt": "2026-10-01T00:00:00.000Z",
						"endsAt": null,
						"groups":
						[
							{
								"id": 20,
								"label": "Control",
								"weight": 5000,
								"ordinal": 0,
								"changeset": {"operations": []}
							},
							{
								"id": 21,
								"label": "Fast",
								"weight": 5000,
								"ordinal": 1,
								"changeset": {"operations": []}
							},
						],
					}
				],
			}
		)
	)


static func _assignment(experiment_id: int, group_id: int) -> Dictionary:
	return {
		"experimentId": experiment_id,
		"groupId": group_id,
		"assignmentVersion": 1,
		"source": "weightedHash",
		"exposureProxyRecorded": true,
	}


func test_assignments_enriched_from_catalog() -> void:
	transport.queued = [
		ConfigTests.config_response("h1", {"Speed": 20}, [_assignment(7, 21)]), _catalog()
	]
	var context := _context()
	var experiments := GamebeastExperiments.new(context)
	var configs := GamebeastConfigs.new(context)
	configs.assignments_reporter = experiments._report
	var events: Array = []
	experiments.assignments_changed.connect(func(list): events.append(list))
	await configs.refresh()
	await settle()
	var catalog_requests := transport.requests_to("/sdk/v2/experiments/active")
	assert_eq(catalog_requests.size(), 1, "catalog fetched for unknown experiment")
	assert_true(catalog_requests[0].url.contains("unit-type=user"), "unit-type query")
	var assignments := experiments.get_assignments()
	assert_eq(assignments.size(), 1, "one assignment")
	var assignment: GamebeastExperimentAssignment = assignments[0]
	assert_eq(assignment.experiment_id, 7, "experiment id")
	assert_eq(assignment.experiment_name, "Speed test", "name")
	assert_eq(assignment.group_label, "Fast", "group label")
	assert_eq(assignment.configuration_alias, "Game", "alias")
	assert_eq(assignment.source, "weightedHash", "source")
	assert_eq(events.size(), 1, "assignments_changed emitted")
	assert_eq(experiments.get_assignment(7).group_id, 21, "lookup by id")
	assert_eq(experiments.get_assignment(99), null, "missing id")


func test_unchanged_assignments_do_not_refetch_catalog() -> void:
	transport.queued = [
		ConfigTests.config_response("h1", {"Speed": 20}, [_assignment(7, 21)]),
		_catalog(),
		ConfigTests.config_response("h2", {"Speed": 21}, [_assignment(7, 21)]),
	]
	var context := _context()
	var experiments := GamebeastExperiments.new(context)
	var configs := GamebeastConfigs.new(context)
	configs.assignments_reporter = experiments._report
	await configs.refresh()
	await settle()
	await configs.refresh()
	await settle()
	assert_eq(transport.requests_to("/sdk/v2/experiments/active").size(), 1, "catalog fetched once")


func test_catalog_failure_still_surfaces_ids() -> void:
	transport.queued = [
		ConfigTests.config_response("h1", {}, [_assignment(7, 21)]), HttpResponse.failed("offline")
	]
	var context := _context()
	var experiments := GamebeastExperiments.new(context)
	var configs := GamebeastConfigs.new(context)
	configs.assignments_reporter = experiments._report
	await configs.refresh()
	await settle()
	var assignment: GamebeastExperimentAssignment = experiments.get_assignments()[0]
	assert_eq(assignment.experiment_id, 7, "id present")
	assert_eq(assignment.experiment_name, "", "name unknown")


func test_identity_change_clears_assignments() -> void:
	var context := _context()
	var experiments := GamebeastExperiments.new(context)
	experiments._catalog[7] = {"id": 7, "name": "x", "groups": []}
	experiments._report("Game", [_assignment(7, 21)])
	await settle()
	assert_eq(experiments.get_assignments().size(), 1, "assigned")
	experiments._on_identity_changed()
	await settle()
	assert_eq(experiments.get_assignments().size(), 0, "cleared for new player")
