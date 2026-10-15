extends Control
## Gamebeast SDK demo. Enter an SDK key (or set Project Settings > Gamebeast > API Key), press
## Setup, then send markers and read configuration values. Runs against the development
## environment from the editor.

@onready var _key_edit: LineEdit = %KeyEdit
@onready var _config_edit: LineEdit = %ConfigEdit
@onready var _cohort_edit: LineEdit = %CohortEdit
@onready var _log: RichTextLabel = %Log


func _ready() -> void:
	_key_edit.text = str(ProjectSettings.get_setting("gamebeast/general/api_key", ""))
	Gamebeast.initialized.connect(
		func(): _print("Initialized as %s." % Gamebeast.get_distinct_id())
	)
	Gamebeast.identity_changed.connect(func(id): _print("Identity is now %s." % id))
	%SetupButton.pressed.connect(_on_setup)
	%MarkerButton.pressed.connect(_on_send_marker)
	%ReadButton.pressed.connect(_on_read)
	%CohortButton.pressed.connect(_on_cohort)
	%IdentifyButton.pressed.connect(func(): Gamebeast.identify("demo-player"))
	%ResetButton.pressed.connect(func(): Gamebeast.reset_identity())


func _on_setup() -> void:
	if Gamebeast.is_initialized():
		_print("Already initialized (%s)." % Gamebeast.get_environment())
		return
	var options := GamebeastOptions.with_api_key(_key_edit.text)
	options.debug_logging = true
	var alias := _config_edit.text.get_slice(".", 0)
	if alias != "":
		options.configurations = PackedStringArray([alias])
	Gamebeast.setup(options)
	if not Gamebeast.is_initialized():
		_print("Setup failed: enter an SDK key.")
		return
	Gamebeast.configs.configs_ready.connect(func(): _print("Configurations ready."))
	Gamebeast.experiments.assignments_changed.connect(_on_assignments)
	_print("Environment: %s" % Gamebeast.get_environment())


func _on_send_marker() -> void:
	if not Gamebeast.is_initialized():
		_print("Press Setup first.")
		return
	Gamebeast.markers.send_marker("demo_button_pressed", {"time": Time.get_ticks_msec()})
	Gamebeast.markers.send_position("demo_position", Vector3(randf() * 100.0, 0.0, randf() * 100.0))
	Gamebeast.markers.flush()
	_print("Sent two markers.")


func _on_read() -> void:
	if not Gamebeast.is_initialized():
		_print("Press Setup first.")
		return
	var path := _config_edit.text.strip_edges()
	Gamebeast.configs.observe(path, func(value): _print("%s = %s" % [path, value]))


func _on_cohort() -> void:
	if not Gamebeast.is_initialized():
		_print("Press Setup first.")
		return
	var cohort := _cohort_edit.text.strip_edges()
	var member: bool = await Gamebeast.cohorts.is_member(cohort)
	_print("Member of '%s': %s" % [cohort, member])


func _on_assignments(assignments: Array) -> void:
	for assignment in assignments:
		_print("Experiment: %s" % assignment)


func _print(text: String) -> void:
	_log.append_text(text + "\n")
